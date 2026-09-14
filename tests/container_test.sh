#!/bin/sh
# 方案 A 端到端测试：在干净的 ubuntu:24.04 容器里，只读挂载 wtool 目录，
# 从零把全部项目装一遍，再全部卸载，核对是否字节级回退。
#
# 宿主机执行（唯一需要的命令）：
#   docker run --rm -it \
#     -v ~/self/wtool:/wtool:ro \
#     -e GIT_OPTIONAL_LOCKS=0 \
#     ubuntu:24.04 \
#     bash /wtool/bootstrap/tests/container_test.sh
#
# 说明：
#   * /wtool 只读挂载；GIT_OPTIONAL_LOCKS=0 让 git 不去写索引，只读挂载也能用
#   * 容器内是 root，$HOME=/root；所有改动都留在容器里，--rm 后什么都不剩
#   * 首次需要网络：apt 换源 + 装 git/zsh（换源用 deb822，正是未来 system-file 的做法）
set -eu

WT=${WT:-/wtool}
PROJECTS="bootstrap shell/oh-my-zsh shell/zsh tools/repo terminal/tmux terminal/fzf"
# 状态目录放到 /tmp，让最后的"完全回退"比对只关注 $HOME 里的配置与软链
export WTOOL_STATE=${WTOOL_STATE:-/tmp/wtool-state}

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$2]  实际 [$3]"; }

# 快照 $HOME。
# 排除两类"不是 wtool 装的"运行时产物：
#   * .zcompdump*   —— zsh 自己的补全缓存
#   * .cache 整棵子树 —— XDG 缓存目录；source oh-my-zsh 时它会往里写，
#                       连 ~/.cache 这个父目录也是它建的。wtool 从不碰 ~/.cache。
snap() {
    find "$HOME" -mindepth 1 -printf '%y %P -> %l\n' \
        | grep -v 'zcompdump' \
        | grep -vE '^[dfl] \.cache( |/)' \
        | sort
}

printf '\n===== 0. 容器环境 =====\n'
grep -E '^(ID|VERSION_ID|VERSION_CODENAME)=' /etc/os-release | sed 's/^/  /'
printf '  用户: %s   家目录: %s\n' "$(id -un)" "$HOME"
for c in git zsh python3; do
    printf '  %-8s %s\n' "$c" "$(command -v $c || echo '缺失')"
done

printf '\n===== 1. 挑一个可用的【HTTP】国内镜像，装最小依赖 =====\n'
# 为什么要用 HTTP：
#   * ubuntu:24.04 镜像里没有 ca-certificates，HTTPS 源会因证书无法验证而全线失败
#   * 国内直连 archive.ubuntu.com 基本连不上（会卡住）
#   * HTTP 镜像的仓库元数据依然有 GPG 签名（Signed-By），安全性不受影响
write_sources() {   # $1 = http(s)://host
    cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $1/ubuntu/
Suites: noble noble-updates noble-backports noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
}

# 让 apt 快速失败而不是长时间卡住（默认超时很长，国内直连官方源会一直挂）
if [ "${WT_SKIP_SETUP:-0}" != 1 ]; then
    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/99wtool-fastfail <<'EOF'
Acquire::http::Timeout "15";
Acquire::https::Timeout "15";
Acquire::Retries "1";
EOF
fi

WT_MIRRORS=${WT_MIRRORS:-"mirrors.ustc.edu.cn mirrors.tuna.tsinghua.edu.cn mirrors.aliyun.com mirrors.huaweicloud.com"}
used_mirror=""
if [ "${WT_SKIP_SETUP:-0}" = 1 ]; then
    printf '  (WT_SKIP_SETUP=1，跳过装包)\n'
else
    for h in $WT_MIRRORS; do
        write_sources "http://$h"
        if timeout 60 apt-get update -qq > /tmp/wtool-apt.log 2>&1; then
            used_mirror=$h
            printf '  使用镜像: http://%s ✓\n' "$h"
            break
        fi
        printf '  镜像 %s 不可用，试下一个\n' "$h"
    done
    if [ -z "$used_mirror" ]; then
        printf 'FAIL  所有 HTTP 镜像都不可用。若需要代理，请这样跑：\n'
        printf '      docker run --rm -it --network host -v ~/self/wtool:/wtool:ro \\\n'
        printf '        -e GIT_OPTIONAL_LOCKS=0 -e http_proxy=http://127.0.0.1:7890 \\\n'
        printf '        -e https_proxy=http://127.0.0.1:7890 ubuntu:24.04 \\\n'
        printf '        bash /wtool/bootstrap/tests/container_test.sh\n'
        sed 's/^/      /' /tmp/wtool-apt.log | tail -5
        exit 1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates git python3 zsh > /tmp/wtool-install.log 2>&1 || {
        printf 'FAIL 安装最小依赖失败：\n'; sed 's/^/      /' /tmp/wtool-install.log | tail -10
        exit 1; }
fi
for c in git python3 zsh; do
    if command -v "$c" >/dev/null 2>&1; then
        printf '  %-8s %s\n' "$c" "$(command -v $c)"
    else
        printf '  %-8s 缺失 ← 必须先装好才能继续\n' "$c"
        fail=$((fail + 1))
    fi
done
[ "$fail" -eq 0 ] || { printf '\n依赖没装上，后面的测试无法进行。\n'; exit 1; }

# 容器里是 root，而挂载进来的仓库属主是宿主用户 → git 的 dubious ownership 检查会
# 拒绝访问，表现为 "不是 git 仓库"。容器里加白名单即可（宿主上不需要）。
if ! git -C "$WT/terminal/fzf" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '  git 起初拒绝访问挂载的仓库，原因：\n'
    git -C "$WT/terminal/fzf" rev-parse --is-inside-work-tree 2>&1 | sed 's/^/      /'
    git config --global --add safe.directory '*'
    printf '  已加 safe.directory=* 修复\n'
fi

printf '\n===== 2. 换成 HTTPS 镜像（现在有证书了），验证 deb822 =====\n'
if [ "${WT_SKIP_SETUP:-0}" != 1 ] && [ -n "$used_mirror" ]; then
    write_sources "https://$used_mirror"
    if timeout 60 apt-get update -qq > /tmp/wtool-apt2.log 2>&1; then
        ok "HTTPS 源 + deb822 被 apt 正常接受"
    else
        printf 'WARN  HTTPS 源暂时不可用（网络问题，不影响后面的引擎测试）\n'
        sed 's/^/      /' /tmp/wtool-apt2.log | tail -5
    fi
fi

printf '\n===== 3. 安装全部项目 =====\n'
# 安装前的 $HOME 快照（最后卸载完要跟它比对）
before=/tmp/wtool-snap-before.txt
snap > "$before"
# rc 文件内容也要能还原，这里留个原始副本
for f in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$f" ] && cp "$f" "/tmp/wtool-orig-$(basename "$f")"
done

install_project() {
    p=$1
    # 引擎要求被安装的仓库工作区干净；容器测试里若发现有未提交改动，用 --force 跳过
    if [ -d "$WT/$p/.git" ] && [ -n "$(git -C "$WT/$p" status --porcelain -uno 2>/dev/null)" ]; then
        printf '  !! %s 有未提交的已跟踪改动 → 用 --force（仅本次容器测试）\n' "$p"
        "$WT/$p/install.sh" --force >/dev/null
    else
        "$WT/$p/install.sh" >/dev/null
    fi
    printf '  ✓ %s\n' "$p"
}
# 故意乱序安装，验证最终顺序只由 priority 决定
for p in terminal/fzf tools/repo shell/oh-my-zsh terminal/tmux shell/zsh bootstrap; do
    install_project "$p"
done

printf '\n===== 4. 验证 =====\n'
export PATH="$WT/bootstrap/bin:$PATH"
eval "$("$WT/bootstrap/wtool.sh" env)"

check "wtool env 的 WTOOL_PREFIX"        "$HOME/.wtool/usr" "$WTOOL_PREFIX"
check "wtool env 识别出 ubuntu"          "ubuntu"           "$WTOOL_OS_ID"
check "wtool env 识别出 24.04"           "24.04"            "$WTOOL_OS_VERSION"
check "wtool env 识别出 noble"           "noble"            "$WTOOL_OS_CODENAME"
check "wtool 命令可用"                   "$WT/bootstrap/bin/wtool" "$(command -v wtool)"

n=$(wtool list | grep -c . || true)
printf '  wtool list: %s 行\n' "$n"
[ "$n" -ge 7 ] && ok "registry 登记了 ≥7 条" || bad "registry 登记了 ≥7 条" "只有 $n 行"

printf '\n  --- ~/.zshrc 里的块顺序（应按 priority 5→10→20→40→50→60）---\n'
grep -o 'wtool:[a-z/-]* schema=1 engine=[0-9.]* prio=[0-9]*' "$HOME/.zshrc" | sed 's/^/    /'
order=$(grep -o 'prio=[0-9]*' "$HOME/.zshrc" | sed 's/prio=//' | tr '\n' ' ')
check "zshrc 块按 priority 升序" "5 10 20 40 50 60 " "$order"

printf '\n  --- ~/.bashrc（bootstrap + fzf）---\n'
grep -o 'wtool:[a-z/-]*' "$HOME/.bashrc" | sort -u | sed 's/^/    /'

printf '\n  --- 软链 ---\n'
printf '    %s\n' "$(readlink "$HOME/.tmux.conf" 2>/dev/null || echo '缺')"

printf '\n  --- 新 zsh 里加载后检查 ---\n'
# 用哨兵包住结果：oh-my-zsh 会往 stdout 打横幅（比如 compaudit 警告），
# 直接比对整段输出会被噪音打断。
zout=$(ZSH_DISABLE_COMPFIX=true zsh -i -c '
    printf "WTCHK:%s|%s|%s|%s|%s" \
      "${ZSH}" \
      "$(( $+functions[cs] ))" \
      "$(( $+functions[cw] ))" \
      "$(( $+aliases[gs] ))" \
      "$(command -v fzf)"
' 2>/dev/null | grep -o 'WTCHK:.*' || true)
zsh_dir="$HOME/.wtool/links/shell/oh-my-zsh"
check "oh-my-zsh 的 ZSH 指向中转链接" \
      "WTCHK:$zsh_dir|1|1|1|$HOME/.wtool/links/terminal/fzf/bin/fzf" "$zout"

printf '\n  --- bash 里 fzf ---\n'
# 必须用 -i：Ubuntu 默认 ~/.bashrc 开头有"非交互就直接 return"的守卫，
# 非交互 bash 根本不会执行我们追加在末尾的块（这在真实机器上也是同样行为）
bout=$(bash -i -c 'command -v fzf' 2>/dev/null | grep -o '/[^ ]*fzf' | tail -1 || true)
check "bash 下 fzf 在 PATH" "$HOME/.wtool/links/terminal/fzf/bin/fzf" "$bout"

printf '\n  --- wtool doctor ---\n'
wtool doctor | sed 's/^/    /'

printf '\n  --- provision 干跑（os/ubuntu：换源 + ansible 装包，不实际执行）---\n'
pout=$(wtool provision "$WT/os/ubuntu" --dry-run --with-system --force 2>&1 || true)
case $pout in
    *"系统文件[replace]"*"/etc/apt/sources.list.d/ubuntu.sources"*)
        ok "识别出 ubuntu 并算出换源目标路径" ;;
    *) bad "识别出 ubuntu 并算出换源目标路径" "$pout" ;;
esac
case $pout in
    *"task[ansible]"*) ok "识别出 ansible 任务" ;;
    *) bad "识别出 ansible 任务" "$pout" ;;
esac
printf '%s\n' "$pout" | sed 's/^/    /'

printf '\n===== 5. 全部卸载，核对是否完全回退 =====\n'
after=/tmp/wtool-snap-after.txt
for p in shell/zsh terminal/tmux shell/oh-my-zsh tools/repo terminal/fzf bootstrap; do
    if [ -d "$WT/$p/.git" ] && [ -n "$(git -C "$WT/$p" status --porcelain -uno 2>/dev/null)" ]; then
        "$WT/$p/uninstall.sh" --force >/dev/null
    else
        "$WT/$p/uninstall.sh" >/dev/null
    fi
done
snap > "$after"
diff_out=$(diff "$before" "$after" 2>/dev/null || true)
check "全部卸载后 \$HOME 与安装前一致" "" "$diff_out"

for f in .bashrc .zshrc; do
    orig="/tmp/wtool-orig-$f"
    if [ -f "$orig" ]; then
        rc_diff=$(diff "$orig" "$HOME/$f" 2>/dev/null || echo "文件缺失或内容不同")
        check "卸载后 $f 内容还原" "" "$rc_diff"
    fi
done

printf '  剩余内容：\n'
find "$HOME" -mindepth 1 -maxdepth 1 | sed "s|^|    |"
rm -f "$before" "$after" /tmp/wtool-orig-.bashrc /tmp/wtool-orig-.zshrc

printf '\n----------------------------------------\n'
printf 'PASS: %d   FAIL: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
