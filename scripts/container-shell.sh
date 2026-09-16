#!/bin/sh
# 在干净的 ubuntu 容器里：装依赖 → 装 wtool → 进入你自己的 zsh
#
# 宿主机执行（一条命令）：
#   docker run --rm -it -v ~/self/wtool:/wtool:ro \
#     ubuntu:24.04 bash /wtool/bootstrap/scripts/container-shell.sh
#
# 可选环境变量（用 -e 传）：
#   WTOOL_ARGS     传给 `wtool bootstrap` 的参数，默认 "--with-system --force"
#                  （带 --force 是因为挂载进来的多半是开发副本，可能有未提交改动）
#                  · --install-only  只做软链与注入，不跑 apt / 编译（最快）
#                  · --no-system     不换系统源，但仍跑 ansible 装包
#   WTOOL_MIRROR   指定镜像源主机名，如 mirrors.aliyun.com（默认自动挑）
#   WTOOL_HEAVY=1  额外装重型工具链（clang/llvm/gcc/gdb/emacs，1GB+，很慢）
#                  不设就只装基础包（zsh/tmux/vim/ripgrep/构建基础），快很多
#   WTOOL_DIR      挂载点，默认 /wtool
#
# 设计约束（都是踩出来的，见 harness/doc/06-排错.md）：
#   · 必须先装 ca-certificates 再换 HTTPS 源，否则证书验证失败
#   · ubuntu 镜像里没有 python3 / git / zsh，全都要装
#   · 容器里是 root 而挂载的仓库属主是宿主用户 → git 需要 safe.directory
#   · 只读挂载 → git 需要 GIT_OPTIONAL_LOCKS=0 才不写索引
set -eu

WTOOL_DIR=${WTOOL_DIR:-/wtool}
WTOOL_ARGS=${WTOOL_ARGS:-"--with-system --force"}
GIT_OPTIONAL_LOCKS=0
export GIT_OPTIONAL_LOCKS

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }

[ -d "$WTOOL_DIR/bootstrap" ] || {
    warn "$WTOOL_DIR 下没有 bootstrap/ —— 挂载点不对？"
    warn "宿主机应该是：docker run ... -v ~/self/wtool:$WTOOL_DIR:ro ..."
    exit 1
}
[ "$(id -u)" = 0 ] || warn "当前不是 root；下面需要 root 权限的步骤可能失败"

# ─────────────────────────────────────────────────────────────
say "1/4 准备依赖（先 HTTP 国内镜像装 ca-certificates，再换 HTTPS）"
if [ "${WTOOL_SKIP_DEPS:-0}" = 1 ]; then
    say "    (WTOOL_SKIP_DEPS=1，跳过)"
else
    # 代号不能写死。这个脚本原来是给 24.04 写的，Suites 固定 noble，
    # 拿到 20.04 上就会去拉 noble 的索引 —— 装出来的是一堆 24.04 的包。
    . /etc/os-release 2>/dev/null || true
    CODENAME=${VERSION_CODENAME:-}
    [ -n "$CODENAME" ] || { warn "读不出 VERSION_CODENAME，/etc/os-release 不对？"; exit 1; }
    printf '    系统: %s %s（%s）\n' "${ID:-?}" "${VERSION_ID:-?}" "$CODENAME"
    printf '    apt: %s\n' "$(apt-get --version 2>/dev/null | head -1 | awk '{print $2}')"

    # 统一写 deb822 的 ubuntu.sources，而且**只写这一个文件**。
    #
    # 我在这里绕过一次弯路，记下来免得再走：
    # 我原本以为"20.04 的 apt 2.0 不认 deb822"，于是给老系统加了个
    # 一行式 .list 的回退。**这个判断是错的** —— 实测 focal 的 apt 2.0.10
    # 完全读得懂 deb822（deb822 支持在 apt 1.1 就有了，2.4 变的只是默认值）。
    #
    # 真正的问题是：os/ubuntu 那份 system-file 也是写 ubuntu.sources 的（deb822），
    # 我的回退又多写了一个 wtool-mirror.list。两个文件指向**同一个 URI**
    # 却一个带 Signed-By、一个不带，apt 直接拒绝读取整份源列表：
    #   E: Conflicting values set for option Signed-By regarding source
    #      https://mirrors.ustc.edu.cn/ubuntu/ focal: ... !=
    # 表现为 apt 彻底瘫痪 —— apt-get update 一行输出都没有，
    # apt-cache 什么都查不到，连"包不存在"都报不出来。
    #
    # 所以：**同一个 URI 只能有一份配置文件**。这里始终用 ubuntu.sources，
    # 并且把其它源文件清干净，让 os/ubuntu 之后在同一路径上替换它。
    write_src() {
        mkdir -p /etc/apt/sources.list.d
        cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $1/ubuntu/
Suites: $CODENAME $CODENAME-updates $CODENAME-backports $CODENAME-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
        # 镜像自带的那份必须删掉。20.04 的镜像是 sources.list（一行式），
        # 24.04 的是 sources.list.d/ubuntu.sources —— 两种都要清，
        # 否则它还指着 archive.ubuntu.com，镜像探测就白做了。
        rm -f /etc/apt/sources.list 2>/dev/null || true
        for _f in /etc/apt/sources.list.d/*; do
            case $_f in
                */ubuntu.sources) ;;
                *) rm -f -- "$_f" 2>/dev/null || true ;;
            esac
        done
    }
    # 让 apt 快速失败，别在国内直连官方源时干等
    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/99wtool-fastfail <<'EOF'
Acquire::http::Timeout "15";
Acquire::https::Timeout "15";
Acquire::Retries "1";
EOF

    MIRRORS=${WTOOL_MIRROR:-"mirrors.ustc.edu.cn mirrors.tuna.tsinghua.edu.cn mirrors.aliyun.com mirrors.huaweicloud.com"}
    used=""
    for h in $MIRRORS; do
        write_src "http://$h"                       # HTTP 不需要证书
        if timeout 90 apt-get update -qq >/dev/null 2>&1; then
            used=$h; printf '    镜像: http://%s ✓\n' "$h"; break
        fi
        printf '    镜像 %s 不可用，下一个\n' "$h"
    done
    [ -n "$used" ] || { warn "所有镜像都不可用；如果你需要代理，加 --network host 和 -e http_proxy=..."; exit 1; }

    # 基础依赖（一定装）；tmux/ripgrep 是为了让你的命令（tmux、rscur）可用
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        ca-certificates git python3 zsh tmux ripgrep curl >/dev/null
    write_src "https://$used"
    apt-get update -qq >/dev/null 2>&1 && printf '    已切到 HTTPS 镜像 ✓\n' || warn "HTTPS 源暂时不可用（不影响后续）"

    # 全套安装才需要 ansible（os/ubuntu 用它装基础软件包）
    #
    # 包名在版本之间变过，不能只试一个：
    #   22.04+ 叫 ansible-core
    #   20.04  只有 ansible（2.9），**没有 ansible-core** ——
    #          只写 ansible-core 的话在 focal 上直接"Unable to locate package"，
    #          然后 os/ubuntu 的 provision 会在缺 ansible-playbook 时失败。
    case " $WTOOL_ARGS " in
        *--install-only*) : ;;
        *)
            _ans=""
            for _p in ansible-core ansible; do
                if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                       --no-install-recommends "$_p" >/dev/null 2>&1 \
                   && command -v ansible-playbook >/dev/null 2>&1; then
                    _ans=$_p; break
                fi
            done
            if [ -n "$_ans" ]; then
                printf '    ansible ✓（包名 %s）\n' "$_ans"
            else
                warn "ansible 装不上（试过 ansible-core / ansible），os/ubuntu 的装包步骤会失败"
            fi ;;
    esac
fi

# ─────────────────────────────────────────────────────────────
say "2/4 让 git 接受挂载进来的仓库"
# 容器里是 root，挂载的仓库属主是宿主用户 → 不加这个 git 会拒绝使用
git config --global --add safe.directory '*' 2>/dev/null || true
printf '    safe.directory=* ✓  GIT_OPTIONAL_LOCKS=0 ✓（只读挂载也能跑）\n'

# ─────────────────────────────────────────────────────────────
say "3/4 装 wtool 引擎，然后装全部项目"
cd "$WTOOL_DIR"
# 根目录的 ./install.sh 是 repo 按 linkfile 建的软链；从发布包解压出来的
# 工作区没有它，所以退回到脚本本体（scripts/ 迁移之后路径变了）。
_engine_install=./install.sh
[ -x "$_engine_install" ] || _engine_install=bootstrap/scripts/install.sh
# 挂载的通常是开发副本，可能有未提交改动 → 用 --force 跳过版本检查
_rc=0
"$_engine_install" --force || _rc=$?
if [ "$_rc" -eq 0 ]; then
    printf '    引擎已装（%s）\n' "$_engine_install"
else
    warn "引擎安装返回 $_rc，继续（下面可能也会失败）"
fi

say "    wtool bootstrap $WTOOL_ARGS"
# ⚠️ 关键：即使这里失败也要走到最后进 shell，
#    否则容器直接退出（docker ps 里就看不到了），你连排查的机会都没有
_rc=0
"$WTOOL_DIR/bootstrap/wtool.sh" bootstrap $WTOOL_ARGS || _rc=$?
if [ "$_rc" -eq 0 ]; then
    printf '    bootstrap 完成\n'
else
    warn "bootstrap 返回 $_rc —— 已经装好的部分仍然可用，下面照常进 shell"
fi

# ─────────────────────────────────────────────────────────────
say "4/4 完成，进入 zsh"
# 标记是 `# >>> wtool >>>`（空格 + 尖括号），不是 `>>> wtool:`。
# 原来 grep 的是带冒号的那个，永远查不到，于是一律显示 0 个块 ——
# 明明装好了却报"0 个 wtool 块"，只会让人以为 rc 注入失败了。
# 另外 `grep -c ... || echo 0` 在查不到时会输出两行（0 和 0），
# 所以用 awk 数，不用 grep -c。
BADGE=$(awk '/>>> wtool >>>/{n++} END{print n+0}' "$HOME/.zshrc" 2>/dev/null)
printf '    ~/.zshrc 里 %s 个 wtool 块\n' "$BADGE"
if [ -n "${WTOOL_HEAVY:-}" ]; then
    printf '    重型工具链(clang/llvm/emacs): 已要求安装\n'
else
    printf '    重型工具链(clang/llvm/emacs): 未装（要装就加 -e WTOOL_HEAVY=1）\n'
fi
printf '    各项目贡献的块: %s\n' "$(grep -o 'wtool:[a-z/-]*' "$HOME/.wtool/.zshrc" 2>/dev/null | sort -u | tr '\n' ' ')"
cat <<'TIP'

  进来之后可以试：
    wtool doctor          # 看环境
    wtool list            # 看装了什么
    cs / cdd / gb         # 你的 repo 辅助命令
    Ctrl+R                # fzf 查历史
    tmux                  # 已装

  会看到 oh-my-zsh 的 "Insecure completion-dependent directories" 警告——
  那是因为容器里以 root 访问宿主目录，属主对不上，忽略即可。
  想静音：export ZSH_DISABLE_COMPFIX=true

TIP
if command -v zsh >/dev/null 2>&1; then
    exec zsh
else
    warn "zsh 没装上，给你 bash"
    exec bash
fi
