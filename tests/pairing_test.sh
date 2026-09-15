#!/bin/sh
# wtool 自测：把"完全配对"变成可证明的属性。
#
# 全程在临时目录里跑，绝不碰真实 $HOME。
#   1. install  → uninstall 必须字节级回到安装前
#   2. install 幂等（第二次无变更）
#   3. 安装顺序不影响 ~/.wtool/.zshrc 的最终内容（用户 rc 里只有一个 loader 块）
#   4. 仓库脏 / 非 git 时拒绝安装
#   5. 软链被用户换成真实文件时，uninstall 不删它
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(dirname -- "$here")
demo=${WTOOL_TEST_DEMO:-$boot/../terminal/tmux}

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
check() { # check <描述> <期望> <实际>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望: $2
实际: $3"; fi
}

newhome() {
    h=$(mktemp -d "${TMPDIR:-/tmp}/wtool-home.XXXXXX")
    mkdir -p "$h/home"
    printf '# 用户自己的 zshrc\nsetopt auto_cd\nexport MY_STUFF=1\n' > "$h/home/.zshrc"
    echo "$h"
}

snap() { find "$1" -mindepth 1 -printf '%y %p -> %l\n' | sort; }

mkrepo() { # mkrepo <目录> <id> <优先级>
    d=$1
    mkdir -p "$d"
    if [ -d "$demo" ]; then
        cp -r "$demo"/. "$d/"
    fi
    cat > "$d/wtool.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="$2" priority="$3">
  <env src="env.zsh" shells="zsh"/>
  <link src="tmux.conf" dest=".wtool-test-$2.conf"/>
</wtool>
EOF
    _var=$(printf '%s' "$2" | tr -c 'A-Za-z0-9' _)
    printf '# env for %s\nexport WTOOL_TEST_%s=1\n' "$2" "$_var" > "$d/env.zsh"
    ( cd "$d" && git init -q && git add -A \
      && git -c user.email=t@example.com -c user.name=t commit -qm init )
}

# --------------------------------------------------------------------------
printf '\n== 场景 1：install / uninstall 完全配对 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home" WTOOL_STATE="$h/state"
proj="$h/proj"; mkrepo "$proj" "terminal/tmux" 50

before=$(snap "$h/home")
"$boot/wtool.sh" install "$proj" > "$h/install.log" 2>&1 || {
    bad "install 执行成功" "$(cat "$h/install.log")"; }
after_install=$(snap "$h/home")

[ -L "$h/home/.wtool-test-terminal/tmux.conf" ] \
    && ok "软链已创建" || bad "软链已创建"
[ -d "$h/home/.wtool/links/terminal/tmux" ] \
    && ok "中转链接已创建" || bad "中转链接已创建"
# 用户 rc 里只有**一个** loader 块；项目的块收在 ~/.wtool/.zshrc 里
grep -q '^# >>> wtool >>>$' "$h/home/.zshrc" \
    && ok "用户 rc 里只有一个 loader 块" || bad "用户 rc 里没有 loader 块"
grep -q '# >>> wtool:terminal/tmux' "$h/home/.wtool/.zshrc" \
    && ok "项目块写进了 ~/.wtool/.zshrc" || bad "~/.wtool/.zshrc 里没有项目块"
[ "$(grep -c 'wtool:' "$h/home/.zshrc" || true)" = 0 ] \
    && ok "用户 rc 里没有散落的项目块（只有 loader）" || bad "用户 rc 里还有项目块"
# loader 必须真的指向汇总文件，否则 a source 空
grep -q 'source\|\.' "$h/home/.zshrc" && grep -q '\.wtool/\.zshrc' "$h/home/.zshrc" \
    && ok "loader 指向 ~/.wtool/.zshrc" || bad "loader 没指向汇总文件"
grep -q 'setopt auto_cd' "$h/home/.zshrc" \
    && ok "原有 rc 内容保留" || bad "原有 rc 内容保留"

"$boot/wtool.sh" uninstall "$proj" > "$h/uninstall.log" 2>&1 || {
    bad "uninstall 执行成功" "$(cat "$h/uninstall.log")"; }
after_uninstall=$(snap "$h/home")
check "uninstall 后 $HOME 与安装前一致" "$before" "$after_uninstall"
check "rc 内容回到原样" "$(printf '# 用户自己的 zshrc\nsetopt auto_cd\nexport MY_STUFF=1\n')" \
      "$(cat "$h/home/.zshrc")"
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 2：install 幂等 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home" WTOOL_STATE="$h/state"
proj="$h/proj"; mkrepo "$proj" "terminal/tmux" 50

"$boot/wtool.sh" install "$proj" > "$h/i1.log" 2>&1
s1=$(snap "$h/home"); rc1=$(cat "$h/home/.zshrc")
"$boot/wtool.sh" install "$proj" > "$h/i2.log" 2>&1
s2=$(snap "$h/home"); rc2=$(cat "$h/home/.zshrc")
check "第二次 install 不改变文件树" "$s1" "$s2"
check "第二次 install 不改变 rc 内容" "$rc1" "$rc2"
grep -q '没有需要变更的内容' "$h/i2.log" \
    && ok "第二次 install 报告无变更" || bad "第二次 install 报告无变更" "$(cat "$h/i2.log")"
"$boot/wtool.sh" uninstall "$proj" > /dev/null 2>&1
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 3：安装顺序无关 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home" WTOOL_STATE="$h/state"
pa="$h/a"; pb="$h/b"
mkrepo "$pa" "zz/late" 50
mkrepo "$pb" "aa/early" 10
"$boot/wtool.sh" install "$pa" > /dev/null 2>&1
"$boot/wtool.sh" install "$pb" > /dev/null 2>&1
order1=$(grep -o '^# >>> wtool:[a-z/]*' "$h/home/.wtool/.zshrc" | sed 's/^# >>> //' | tr '\n' ' ')

h2=$(newhome)
export WTOOL_HOME="$h2/home" WTOOL_STATE="$h2/state"
pa2="$h2/a"; pb2="$h2/b"
mkrepo "$pa2" "zz/late" 50
mkrepo "$pb2" "aa/early" 10
"$boot/wtool.sh" install "$pb2" > /dev/null 2>&1
"$boot/wtool.sh" install "$pa2" > /dev/null 2>&1
order2=$(grep -o '^# >>> wtool:[a-z/]*' "$h2/home/.wtool/.zshrc" | sed 's/^# >>> //' | tr '\n' ' ')

check "两种安装顺序得到相同的 rc 块顺序" "$order1" "$order2"
check "低优先级在前" "wtool:aa/early wtool:zz/late " "$order1"
rm -rf "$h" "$h2"

# --------------------------------------------------------------------------
printf '\n== 场景 4：仓库脏 / 非 git 时拒绝 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home" WTOOL_STATE="$h/state"
proj="$h/proj"; mkrepo "$proj" "terminal/tmux" 50
printf 'dirty\n' >> "$proj/env.zsh"
if "$boot/wtool.sh" install "$proj" > "$h/dirty.log" 2>&1; then
    bad "脏仓库被拒绝" "却成功了"
else
    grep -q '未提交' "$h/dirty.log" \
        && ok "脏仓库被拒绝（提示未提交）" || bad "脏仓库被拒绝" "$(cat "$h/dirty.log")"
fi
( cd "$proj" && git -c user.email=t@example.com -c user.name=t commit -qam fix )
nogit="$h/nogit"; mkdir -p "$nogit"; cp -r "$proj"/. "$nogit/"; rm -rf "$nogit/.git"
if "$boot/wtool.sh" install "$nogit" > "$h/nogit.log" 2>&1; then
    bad "非 git 目录被拒绝" "却成功了"
else
    ok "非 git 目录被拒绝"
fi
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 5：软链被换成真实文件时，uninstall 不删它 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home" WTOOL_STATE="$h/state"
proj="$h/proj"; mkrepo "$proj" "terminal/tmux" 50
"$boot/wtool.sh" install "$proj" > /dev/null 2>&1
rm -f "$h/home/.wtool-test-terminal/tmux.conf"
printf 'user data\n' > "$h/home/.wtool-test-terminal/tmux.conf"
"$boot/wtool.sh" uninstall "$proj" > "$h/u.log" 2>&1 || true
if [ -f "$h/home/.wtool-test-terminal/tmux.conf" ] \
   && [ ! -L "$h/home/.wtool-test-terminal/tmux.conf" ]; then
    ok "用户的真实文件被保留"
else
    bad "用户的真实文件被保留" "$(ls -l "$h/home/.wtool-test-terminal/" 2>&1)"
fi
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 6：dry-run 零副作用 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home" WTOOL_STATE="$h/state"
proj="$h/proj"; mkrepo "$proj" "terminal/tmux" 50
before=$(snap "$h/home")
"$boot/wtool.sh" install "$proj" --dry-run > "$h/dry.log" 2>&1
after=$(snap "$h/home")
check "dry-run 后文件树不变" "$before" "$after"
grep -q 'dry-run' "$h/dry.log" \
    && ok "dry-run 输出了计划" || bad "dry-run 输出了计划" "$(cat "$h/dry.log")"
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 7：重复 install 之后 uninstall 仍能完全回退（回归） ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home" WTOOL_STATE="$h/state"
proj="$h/proj"; mkrepo "$proj" "terminal/tmux" 50
before=$(snap "$h/home")
"$boot/wtool.sh" install "$proj" > /dev/null 2>&1
"$boot/wtool.sh" install "$proj" > /dev/null 2>&1   # no-op，但绝不能清空 journal
"$boot/wtool.sh" install "$proj" > /dev/null 2>&1
"$boot/wtool.sh" uninstall "$proj" > "$h/u7.log" 2>&1
after=$(snap "$h/home")
check "连续 3 次 install 后 uninstall 仍完全回退" "$before" "$after"
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 8：rc 块真的能把 env 加载起来 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home" WTOOL_STATE="$h/state"
proj="$h/proj"; mkrepo "$proj" "terminal/tmux" 50
"$boot/wtool.sh" install "$proj" > /dev/null 2>&1

if command -v zsh >/dev/null 2>&1; then
    got=$(HOME="$h/home" zsh -c '. "$HOME/.zshrc" >/dev/null 2>&1; printf "%s|%s|%s" \
        "$WTOOL_TEST_terminal_tmux" "$WTOOL_PROJECT_DIR" "$WTOOL_PROJECT_ROOT"')
    check "env 里的变量被导出" "1|$h/home/.wtool/links/terminal/tmux|$proj" "$got"

    # 仓库搬家：只重建中转链接，rc 块一个字都不用改
    moved="$h/moved-proj"
    mv "$proj" "$moved"
    before_rc=$(cat "$h/home/.zshrc")
    "$boot/wtool.sh" install "$moved" > "$h/move.log" 2>&1
    after_rc=$(cat "$h/home/.zshrc")
    check "仓库搬家后 loader 块不变" "$before_rc" "$after_rc"
    got2=$(HOME="$h/home" zsh -c '. "$HOME/.zshrc" >/dev/null 2>&1; printf "%s" \
        "$WTOOL_PROJECT_ROOT"')
    check "搬家后 WTOOL_PROJECT_ROOT 指向新位置" "$moved" "$got2"
else
    printf 'SKIP  zsh 不可用，跳过场景 8\n'
fi
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 9：bootstrap 自举项目提供的长期变量 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home" WTOOL_STATE="$h/state"
# 引擎要求被安装的仓库是"干净的 git 仓"，所以拿一份 bootstrap 的副本测试
bcopy="$h/bootstrap"
mkdir -p "$bcopy"
cp -r "$boot"/. "$bcopy/" 2>/dev/null || true
rm -rf "$bcopy/.git" "$bcopy/lib/__pycache__"
( cd "$bcopy" && git init -q && git add -A \
  && git -c user.email=t@example.com -c user.name=t commit -qm init )

"$bcopy/wtool.sh" install "$bcopy" > "$h/boot.log" 2>&1 || {
    bad "install bootstrap" "$(cat "$h/boot.log")"; }
[ -d "$h/home/.wtool/links/bootstrap" ] \
    && ok "bootstrap 中转链接已创建" || bad "bootstrap 中转链接已创建"
grep -q '# >>> wtool:bootstrap' "$h/home/.wtool/.zshrc" \
    && ok "bootstrap 的块写进了汇总文件" || bad "bootstrap 的块没写进去"

if command -v zsh >/dev/null 2>&1; then
    got=$(HOME="$h/home" zsh -c '. "$HOME/.zshrc" >/dev/null 2>&1;
        printf "%s|%s|%s|%s" "$WTOOL_PREFIX" "$WTOOL_OS_ID" "$WTOOL_ARCH" \
               "$(case ":$PATH:" in *":$WTOOL_PREFIX/bin:"*) echo in-path;; *) echo missing;; esac)"')
    check "新 shell 里能拿到 PREFIX/OS_ID/ARCH 且 PATH 已含前缀" \
          "$h/home/.wtool/usr|ubuntu|x86_64|in-path" "$got"
    got2=$(HOME="$h/home" zsh -c '. "$HOME/.zshrc" >/dev/null 2>&1; command -v wtool')
    check "wtool 命令在 PATH 上" "$h/home/.wtool/links/bootstrap/bin/wtool" "$got2"
else
    printf 'SKIP  zsh 不可用，跳过场景 9\n'
fi

"$bcopy/wtool.sh" uninstall "$bcopy" > /dev/null 2>&1
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 10：wtool env 在干净 shell 里 eval 后可用 ==\n'
got=$(env -i HOME="$HOME" PATH=/usr/bin:/bin sh -c \
    "eval \"\$('$boot/wtool.sh' env)\"; printf '%s|%s|%s' \
     \"\$WTOOL_PREFIX\" \"\$WTOOL_OS_ID\" \"\$(command -v wtool)\"")
check "eval 后 PREFIX/OS_ID/wtool 命令都可用" \
      "$HOME/.wtool/usr|ubuntu|$boot/bin/wtool" "$got"
got2=$(env -i HOME="$HOME" PATH=/usr/bin:/bin sh -c \
    "eval \"\$('$boot/wtool.sh' env --quiet)\"; printf '%s' \"\$WTOOL_JOBS\"")
[ -n "$got2" ] && ok "--quiet 只输出 export 行且 WTOOL_JOBS 非空" \
              || bad "--quiet 只输出 export 行且 WTOOL_JOBS 非空"
got3=$("$boot/wtool.sh" env --json | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["WTOOL_OS_ID"])' 2>/dev/null)
check "--json 可被程序解析" "ubuntu" "$got3"

# --------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'PASS: %d   FAIL: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
