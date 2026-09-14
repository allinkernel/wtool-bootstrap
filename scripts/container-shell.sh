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
    write_src() {
        mkdir -p /etc/apt/sources.list.d
        cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $1/ubuntu/
Suites: noble noble-updates noble-backports noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
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
    case " $WTOOL_ARGS " in
        *--install-only*) : ;;
        *) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
               ansible-core >/dev/null 2>&1 \
               && printf '    ansible-core ✓\n' || warn "ansible-core 装不上，os/ubuntu 的装包步骤会失败" ;;
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
# 挂载的通常是开发副本，可能有未提交改动 → 用 --force 跳过版本检查
./install.sh --force
printf '    引擎已装（根目录 linkfile → bootstrap/install.sh）\n'

say "    wtool bootstrap $WTOOL_ARGS"
"$WTOOL_DIR/bootstrap/wtool.sh" bootstrap $WTOOL_ARGS

# ─────────────────────────────────────────────────────────────
say "4/4 完成，进入 zsh"
BADGE=$(grep -c '>>> wtool:' "$HOME/.zshrc" 2>/dev/null || echo 0)
printf '    ~/.zshrc 里 %s 个 wtool 块\n' "$BADGE"
printf '    %s\n' "$(grep -o 'wtool:[a-z/-]*' "$HOME/.zshrc" 2>/dev/null | sort -u | tr '\n' ' ')"
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
exec zsh
