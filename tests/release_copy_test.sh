#!/bin/sh
# release_copy_test.sh —— 测"从发布包解压出来的工作区"这条路
#
# 这条路的目标用户是：拿到一台干净机器、访问不了 GitHub 命令行、
# 只能用浏览器把发布包一个个下下来解开的人。
#
# 它和 `repo sync` 出来的工作区有几处关键差别，每一处都踩过坑：
#   1. 项目不是 git 仓库（发布包里没有 .git）—— install 必须认发布标记放行
#   2. 没有 repo 客户端，所以没有根目录那几条 linkfile 软链 —— 必须补上
#   3. 项目表得靠 .wtool-dist 里的标记找全（harness 这种没有 wtool.xml 的）
#
# 全程在临时目录里跑，不碰真 $HOME、不碰真工作区。
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
bootstrap=$(cd -- "$here/.." && pwd)
WT="$bootstrap/wtool.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3] 实际 [$2]）"; fi; }
has()   { if [ -e "$2" ]; then ok "$1"; else bad "$1（$2 不存在）"; fi; }
hasnt() { if [ ! -e "$2" ]; then ok "$1"; else bad "$1（$2 不该存在）"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-relcopy.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

# --------------------------------------------------------------------------
# 造一个"解压出来的工作区"：两个项目，都没有 .git，都带发布标记
# --------------------------------------------------------------------------
WS="$T/ws"
mkdir -p "$WS/.wtool-dist" "$WS/terminal/tmux" "$WS/harness" \
         "$WS/bootstrap" "$WS/wtool-base"

cat > "$WS/terminal/tmux/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="terminal/tmux" priority="50">
  <env src="env.zsh" shells="zsh"/>
</wtool>
EOF
echo 'export TMUX_DEMO=1' > "$WS/terminal/tmux/env.zsh"

# harness：没有 wtool.xml，只能靠发布标记找到它
echo 'agent notes' > "$WS/harness/notes.md"

# bootstrap / wtool-base：假装是发布包解压出来的，用来验工作区入口
cp -f "$bootstrap/wtool.sh" "$WS/bootstrap/wtool.sh"
mkdir -p "$WS/bootstrap/lib"
cp -f "$bootstrap/lib/"*.py "$WS/bootstrap/lib/" 2>/dev/null || true
cat > "$WS/bootstrap/install.sh" <<'EOF'
#!/bin/sh
echo "bootstrap install.sh 被调用了（WTOOL_PROJECT_ID=${WTOOL_PROJECT_ID:-未设置}）"
EOF
cp -f "$bootstrap/uninstall.sh" "$WS/bootstrap/uninstall.sh"
chmod +x "$WS/bootstrap/install.sh" "$WS/bootstrap/uninstall.sh"
echo '# 用户文档' > "$WS/wtool-base/README.md"
echo '# 使用指南' > "$WS/wtool-base/guide.md"

cat > "$WS/.wtool-dist/terminal-tmux.json" <<'EOF'
{"project":"terminal/tmux","repo":"allinkernel/wtool-tmux-config",
 "commit":"d0a872a1234567890abcdef1234567890abcdef","dirty":false,
 "view":"release","layout":"wtool/terminal/tmux"}
EOF
cat > "$WS/.wtool-dist/harness.json" <<'EOF'
{"project":"harness","repo":"allinkernel/wtool-harness",
 "commit":"cebe7c911112222333344445555666677778888","dirty":false,
 "view":"release","layout":"wtool/harness"}
EOF

echo "== 1. 解压副本不带 .git，install 必须认发布标记放行 =="
H="$T/home"; mkdir -p "$H"
env HOME="$H" WTOOL_ROOT="$WS" WTOOL_STATE="$T/state" \
    "$WT" install "$WS/terminal/tmux" > "$T/log1" 2>&1 || {
    bad "install 失败"; sed 's/^/     /' "$T/log1"; }
grep -q '发布副本' "$T/log1" && ok "认出了这是发布副本" || bad "没认出发布副本"
grep -q 'd0a872a12345' "$T/log1" && ok "版本取自标记里的 commit" || bad "没取到 commit"
has "软链接建好了" "$H/.wtool/links/terminal/tmux"
has "用户 rc 里写了 loader 块" "$H/.zshrc"
has "环境变量汇总文件也写了" "$H/.wtool/.zshrc"
grep -q '^# >>> wtool >>>$' "$H/.zshrc" \
    && ok "用户 rc 里只有 loader 块" || bad "用户 rc 里的块不对"
grep -q 'TMUX_DEMO\|terminal/tmux' "$H/.wtool/.zshrc" \
    && ok "项目的 env 收在 ~/.wtool/.zshrc 里" || bad "汇总文件里没有这个项目"

echo "== 2. 没有标记的目录仍然拒绝（别把门开太大）=="
mkdir -p "$WS/plain"
sed 's|terminal/tmux|plain|' "$WS/terminal/tmux/wtool.xml" > "$WS/plain/wtool.xml"
_rc=0
env HOME="$H" WTOOL_ROOT="$WS" WTOOL_STATE="$T/state" \
    "$WT" install "$WS/plain" > "$T/log2" 2>&1 || _rc=$?
chk "拒绝时退出码非 0" "$([ "$_rc" != 0 ] && echo yes || echo no)" "yes"
grep -q '不是 git 仓库' "$T/log2" && ok "说了为什么拒绝" || bad "没说原因"

echo "== 3. 项目表靠发布标记找全（harness 没有 wtool.xml）=="
TAB=$(env HOME="$H" WTOOL_ROOT="$WS" WTOOL_STATE="$T/state" \
      python3 "$bootstrap/lib/wtool_plan.py" table --root "$WS" --state "$T/state")
printf '%s\n' "$TAB" | awk '$1=="harness"{print "     " $0}'
chk "harness 出现在表里" \
    "$(printf '%s\n' "$TAB" | awk '$1 == "harness" {print $1}' | head -1)" "harness"
chk "terminal/tmux 也在" \
    "$(printf '%s\n' "$TAB" | awk '$1 == "terminal/tmux" {print $1}' | head -1)" "terminal/tmux"

echo "== 4. 工作区入口：没有 repo 客户端也要有根目录软链 =="
# bootstrap/install.sh 自己会补这几条（repo 的 linkfile 只能覆盖 repo 客户端）
cat > "$WS/bootstrap/install.sh" <<'EOF'
#!/bin/sh
set -eu
self=$0
while [ -L "$self" ]; do
    t=$(readlink -- "$self"); case $t in /*) self=$t ;; *) self=$(dirname -- "$self")/$t ;; esac
done
here=$(cd -- "$(dirname -- "$self")" && pwd)
ws=$(dirname -- "$here")
_ln() {
    _dest=$ws/$1; _target=$2
    if [ -L "$_dest" ]; then
        [ "$(readlink -- "$_dest")" = "$_target" ] && return 0
    elif [ -e "$_dest" ]; then return 0; fi
    [ -e "$ws/$_target" ] || return 0
    ln -sfn -- "$_target" "$_dest"
}
_ln install.sh   bootstrap/install.sh
_ln uninstall.sh bootstrap/uninstall.sh
_ln README.md    wtool-base/README.md
_ln guide.md     wtool-base/guide.md
EOF
chmod +x "$WS/bootstrap/install.sh"
env HOME="$H" "$WS/bootstrap/install.sh" > "$T/log4" 2>&1 || true
for l in install.sh uninstall.sh README.md guide.md; do
    if [ -L "$WS/$l" ]; then
        ok "根目录 $l -> $(readlink -- "$WS/$l")"
    else
        bad "根目录 $l 没建出来"
    fi
done

echo "== 5. 入口软链不能覆盖用户的真实文件 =="
WS2="$T/ws2"; mkdir -p "$WS2/bootstrap" "$WS2/wtool-base"
cp -f "$WS/bootstrap/install.sh" "$WS2/bootstrap/install.sh"
echo '# 我自己写的 README' > "$WS2/wtool-base/README.md"
echo 'this is mine' > "$WS2/README.md"          # 真实文件，不是软链
env HOME="$H" "$WS2/bootstrap/install.sh" >/dev/null 2>&1 || true
chk "用户的真实 README.md 没被覆盖" "$(cat "$WS2/README.md")" "this is mine"

echo
printf 'release_copy_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
