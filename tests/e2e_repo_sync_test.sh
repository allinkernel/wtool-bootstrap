#!/bin/sh
# 模式 B 端到端：真实跑一遍 repo init → repo sync → 项目 install/uninstall
#
# 用「本地 bare 镜像 + 本地清单仓」代替 github，所以：
#   * 不需要 push、不需要网络、不需要 docker
#   * 可以在本机反复验证整条链路
#
# ⚠️ 安全纪律（见 harness/notes/03-hazards.md G 节）：
#   1. repo init 只在 $WORK 里跑，跑之前断言 pwd —— 曾经因为变量为空
#      在用户的 repo client 里裸跑过 repo init，把 .repo/repo 退回了 v2.9
#   2. 所有临时目录放在工作区内（agent 的 /tmp 不跨调用保留）
#   3. 变量用在路径前先检查非空
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(dirname -- "$here")
wtool_root=$(dirname -- "$boot")
REPO_BIN=${REPO_BIN:-$HOME/bin/repo}
REPO_TOOL_SRC=${REPO_TOOL_SRC:-$wtool_root/.repo/repo}

# ⚠️⚠️ 安全闸（血的教训，见 harness/notes/03-hazards.md G 节）：
#   repo 会【向上逐级查找】已有的 .repo，一旦找到就"复用那个 client"。
#   所以测试目录绝不能放在任何 repo client 里面，否则 repo init 会直接
#   改写用户的 client（曾两次把 ~/self/wtool 的 manifests 清空到 unborn HEAD）。
WORK=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/wtool-e2e.XXXXXX")}
[ -n "$WORK" ] || { echo "WORK 为空，中止"; exit 1; }
case "$WORK" in
    "$wtool_root"|"$wtool_root"/*)
        echo "拒绝执行：WORK=$WORK 在 wtool 工作区内部，"
        echo "repo 会向上找到 $wtool_root/.repo 并改坏用户的 client。"
        exit 1 ;;
esac
_d=$WORK
while [ "$_d" != "/" ]; do
    [ -e "$_d/.repo" ] && { echo "拒绝执行：$WORK 的祖先 $_d 是一个 repo client"; exit 1; }
    _d=$(dirname -- "$_d")
done
[ -x "$REPO_BIN" ] || { echo "找不到 repo 工具: $REPO_BIN（可用 REPO_BIN= 指定）"; exit 1; }
echo "  工作目录: $WORK（已确认在任何 repo client 之外）"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$2]  实际 [$3]"; }

PROJECTS="bootstrap:base shell/oh-my-zsh:shell shell/zsh:shell tools/repo:tools terminal/tmux:terminal terminal/fzf:terminal"

printf '\n===== 1. 准备本地镜像与清单仓 =====\n'
rm -rf "$WORK"
mkdir -p "$WORK/mirrors" "$WORK/manifest" "$WORK/checkout"

# repo 工具本身也做成本地镜像（避免联网）
git clone -q --bare "$REPO_TOOL_SRC" "$WORK/mirrors/git-repo.git"
printf '  repo 工具镜像: %s\n' "$(git -C "$WORK/mirrors/git-repo.git" log -1 --format='%h %s' wsw 2>/dev/null || echo '取不到 wsw 分支')"

for spec in $PROJECTS; do
    p=${spec%%:*}
    name=$(printf '%s' "$p" | tr '/' '-')
    git clone -q --bare "$wtool_root/$p" "$WORK/mirrors/$name.git"
    # 记录每个仓真实的分支名 —— 镜像里没有 main 就会 sync 失败
    br=$(git -C "$wtool_root/$p" rev-parse --abbrev-ref HEAD)
    eval "BRANCH_$(printf '%s' "$name" | tr '-' '_')=\$br"
    printf '  镜像 %-18s -> %s.git  (分支 %s)\n' "$p" "$name" "$br"
done

cat > "$WORK/manifest/default.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="local" fetch="file://$WORK/mirrors" />
  <default revision="main" remote="local" sync-j="4" />
$(for spec in $PROJECTS; do
    p=${spec%%:*}; g=${spec##*:}; name=$(printf '%s' "$p" | tr '/' '-')
    var="BRANCH_$(printf '%s' "$name" | tr '-' '_')"
    eval "br=\$$var"
    printf '  <project path="%s" name="%s" groups="%s" revision="%s"/>\n' "$p" "$name" "$g" "$br"
  done)
</manifest>
XML
( cd "$WORK/manifest" && git init -q -b main && git add -A \
  && git -c user.email=t@example.com -c user.name=t commit -qm "本地清单" )
printf '  清单仓就绪（6 个项目）\n'

printf '\n===== 2. repo init（只在 %s 里跑）=====\n' "$WORK/checkout"
cd "$WORK/checkout"
[ "$(pwd)" = "$WORK/checkout" ] || { echo "cd 失败，中止（绝不在别处跑 repo init）"; exit 1; }
export REPO_URL="$WORK/mirrors/git-repo.git"
export REPO_REV=wsw
timeout 300 "$REPO_BIN" init -u "file://$WORK/manifest" -b main > "$WORK/init.log" 2>&1 || {
    bad "repo init" "$(tail -5 "$WORK/init.log")"
    printf '\ninit 失败，中止\n'; exit 1; }
ok "repo init 成功"
[ -d .repo ] && ok "已生成 .repo" || bad "已生成 .repo"

printf '\n===== 3. repo sync =====\n'
timeout 600 "$REPO_BIN" sync -c -j4 > "$WORK/sync.log" 2>&1 || {
    bad "repo sync" "$(tail -8 "$WORK/sync.log")"
    printf '\n--- 日志尾部 ---\n'; tail -15 "$WORK/sync.log"; exit 1; }
ok "repo sync 成功"
for spec in $PROJECTS; do
    p=${spec%%:*}
    if [ -f "$p/wtool.xml" ]; then printf '  ✓ %s\n' "$p"
    else bad "同步出 $p"; fi
done

printf '\n===== 4. 在同步出来的副本上跑 install / uninstall =====\n'
HOME_FAKE="$WORK/home"; mkdir -p "$HOME_FAKE"
printf '# 我的 zshrc\n' > "$HOME_FAKE/.zshrc"
export WTOOL_HOME="$HOME_FAKE" WTOOL_STATE="$WORK/state"
before=$(find "$HOME_FAKE" -mindepth 1 -printf '%y %P -> %l\n' | sort)
for spec in $PROJECTS; do
    p=${spec%%:*}
    ( cd "$p" && ./install.sh --force >/dev/null 2>&1 ) \
        && printf '  ✓ install %s\n' "$p" || bad "install $p"
done
grep -q '# >>> wtool:terminal/tmux' "$HOME_FAKE/.zshrc" \
    && ok "rc 块已写入同步出来的工作区" || bad "rc 块已写入"
[ -L "$HOME_FAKE/.tmux.conf" ] && ok "软链已建立" || bad "软链已建立"

for spec in $PROJECTS; do
    p=${spec%%:*}
    ( cd "$p" && ./uninstall.sh --force >/dev/null 2>&1 ) || bad "uninstall $p"
done
after=$(find "$HOME_FAKE" -mindepth 1 -printf '%y %P -> %l\n' | sort)
diff_out=$(diff "$before" "$after" 2>/dev/null || true)
check "全部卸载后 \$HOME 完全回退" "" "$diff_out"

printf '\n===== 5. 清理 =====\n'
cd "$wtool_root"
rm -rf "$WORK"
[ -d "$WORK" ] && bad "清理 $WORK" || ok "已清理 $WORK"

printf '\n----------------------------------------\n'
printf 'PASS: %d   FAIL: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
