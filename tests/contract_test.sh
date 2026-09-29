#!/bin/sh
# contract_test.sh —— 新契约的端到端验证
#
# 这一组守的是"改了会静默出事"的那几条：
#   1. wtool.xml 新标签：<zshrc>/<bashrc>、三段 <link>、<sudo-install>
#   2. 旧标签仍然认（过渡期），但要**警告**，不能静默
#   3. <link> 是两跳：<项目>/x → ~/.wtool/x → ~/x（仓库搬家不断链）
#   4. 执行顺序：install.sh（output/ → ~/.wtool）在前，XML 软链（影子 → $HOME）在后
#   5. 有 build.sh/download.sh 就必须先有 output/（install 不替你编）
#   6. ~/usr → ~/.wtool/usr 这条全局软链：有项目就活着，一个不剩就收走
#   7. uninstall 拆软链前先问"还有别人要用吗"（判据是磁盘上的 wtool.xml）
#   8. check / repair：只报不改 / 只重建不删除
#   9. kill-self-forever：要逐字确认；删 wtool 的、不删别人的
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(dirname -- "$here")
WT="$boot/wtool.sh"

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
# 注意最后要 return 0：不然"只带一个参数的 bad"会让函数返回非 0，
# 在 set -e 的脚本里直接终止整组测试（踩过）。
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"
         if [ $# -gt 1 ]; then printf '      %s\n' "$2"; fi; return 0; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$2]  实际 [$3]"; }
chk()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$3]  实际 [$2]"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-contract.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

newhome() {
    H=$(mktemp -d "$T/home.XXXXXX")
    mkdir -p "$H"
    printf '# 用户自己的 zshrc\nsetopt auto_cd\nexport MY_STUFF=1\n' > "$H/.zshrc"
    # state 每个场景一份：共用一份的话，前面场景留下的 state 会让
    # "还有没有项目装着"算错（~/usr 的生命周期那一场就是这么被坑的）
    export WTOOL_HOME="$H" WTOOL_STATE="$H.state"
    export WTOOL_ROOT="$T/ws"
}
mkproj() {   # <相对路径> <id>
    d="$T/ws/$1"; mkdir -p "$d"
    git -C "$d" init -q
    echo "$d"
}

# --------------------------------------------------------------------------
printf '\n== 场景 1：新标签全用上（zshrc/bashrc + 三段 link + produced-by）==\n'
newhome
mkdir -p "$WTOOL_ROOT"
P=$(mkproj "terminal/tmux" "terminal/tmux")
printf 'set -g mouse on\n' > "$P/tmux.conf"
printf 'export TMUX_MARK=1\n' > "$P/env.zsh"
printf 'export TMUX_MARK=1\n' > "$P/env.bash"
mkdir -p "$P/output" "$P/scripts"
printf 'payload\n' > "$P/output/foo.conf"
cat > "$P/scripts/install.sh" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--uninstall" ]; then
    # 卸载时要**先**拆完 $HOME 软链才轮到脚本（§4.2 的 ②' → ①'）
    if [ -e "$WTOOL_HOME/.tmux.conf" ] || [ -e "$WTOOL_HOME/.config/foo/foo.conf" ]; then
        echo "links-still-there" > "$WTOOL_PROJECT_DIR/order-uninstall.txt"
    else
        echo "links-gone" > "$WTOOL_PROJECT_DIR/order-uninstall.txt"
    fi
    exit 0
fi
# 项目脚本按契约把 output/ 铺到影子 HOME（~/.wtool）
mkdir -p "$WTOOL_HOME/.wtool/.config/foo"
cp "$WTOOL_PROJECT_DIR/output/foo.conf" "$WTOOL_HOME/.wtool/.config/foo/foo.conf"
# 顺手记一笔：这一刻 $HOME 里那条链**应该还不存在**（执行顺序见 §4.2）
if [ -e "$WTOOL_HOME/.config/foo/foo.conf" ]; then
    echo "link-existed-too-early" > "$WTOOL_PROJECT_DIR/order.txt"
else
    echo "link-not-yet" > "$WTOOL_PROJECT_DIR/order.txt"
fi
EOF
cat > "$P/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="terminal/tmux" priority="50">
  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>
  <link home="~/.tmux.conf" wtool="~/.wtool/.tmux.conf" subproject="tmux.conf"/>
  <link home="~/.config/foo/foo.conf" wtool="~/.wtool/.config/foo/foo.conf"
        produced-by="install.sh"/>
</wtool>
EOF
git -C "$P" add -A && git -C "$P" -c user.name=t -c user.email=t@t commit -qm init

_rc=0
"$WT" validate "$P" > "$T/v1.log" 2>&1 || _rc=$?
chk "新标签的清单 validate 通过" "$_rc" "0"
"$WT" install "$P" > "$T/i1.log" 2>&1 || bad "install 执行" "$(cat "$T/i1.log")"

# 两跳：项目文件 → ~/.wtool/.tmux.conf → ~/.tmux.conf
check "中间那一跳指向项目文件" \
    "$WTOOL_HOME/.wtool/wtool-work-dir/links/terminal/tmux/tmux.conf" \
    "$(readlink "$WTOOL_HOME/.wtool/.tmux.conf" 2>/dev/null)"
check "最后一跳指向影子 HOME" "$WTOOL_HOME/.wtool/.tmux.conf" \
    "$(readlink "$WTOOL_HOME/.tmux.conf" 2>/dev/null)"
[ -r "$WTOOL_HOME/.tmux.conf" ] && ok "两跳之后文件打得开（不是断链）" \
    || bad "两跳之后是断链"
check "顺着链读到内容" "set -g mouse on" "$(cat "$WTOOL_HOME/.tmux.conf" 2>/dev/null)"

# produced-by：实体由 install.sh 铺，链由引擎铺，且**不悬空**
check "produced-by 的链指向影子 HOME" \
    "$WTOOL_HOME/.wtool/.config/foo/foo.conf" \
    "$(readlink "$WTOOL_HOME/.config/foo/foo.conf" 2>/dev/null)"
[ -r "$WTOOL_HOME/.config/foo/foo.conf" ] && ok "produced-by 的链不悬空（顺序对）" \
    || bad "produced-by 的链悬空 —— 执行顺序反了"
check "install.sh 跑的时候 \$HOME 里还没有那条链" "link-not-yet" \
    "$(cat "$P/order.txt" 2>/dev/null)"

# ~/usr 这条全局软链
[ -L "$WTOOL_HOME/usr" ] && ok "~/usr 建出来了" || bad "~/usr 没建出来"
check "~/usr 指向 ~/.wtool/usr" "$WTOOL_HOME/.wtool/usr" \
    "$(readlink "$WTOOL_HOME/usr" 2>/dev/null)"

# 新标签的路径也要幂等（两跳 + env.bash，重复 install 不该有任何变化）
_snap1=$(find "$WTOOL_HOME" -mindepth 1 -printf '%y %p -> %l\n' | LC_ALL=C sort)
_rc1=$(cat "$WTOOL_HOME/.zshrc")
"$WT" install "$P" > "$T/i1b.log" 2>&1 || bad "第二次 install 执行"
_snap2=$(find "$WTOOL_HOME" -mindepth 1 -printf '%y %p -> %l\n' | LC_ALL=C sort)
check "第二次 install 不改变文件树" "$_snap1" "$_snap2"
check "第二次 install 不改变 rc 内容" "$_rc1" "$(cat "$WTOOL_HOME/.zshrc")"
grep -q '没有需要变更的内容' "$T/i1b.log" && ok "第二次 install 报无变更" \
    || bad "第二次 install 没报无变更" "$(cat "$T/i1b.log")"

# env 两份都进了汇总：汇总文件里放的是**块**（运行时 source 项目的 env 文件），
# 不是把内容抄进去 —— 所以查的是块和它 source 的那一行
grep -q 'wtool:terminal/tmux' "$WTOOL_HOME/.wtool/.zshrc" \
    && ok "zshrc 的块进了汇总" || bad "zshrc 的块没进汇总"
grep -q 'env.zsh' "$WTOOL_HOME/.wtool/.zshrc" \
    && ok "zshrc 的块 source 的是 env.zsh" || bad "zshrc 的块 source 错了"
grep -q 'env.bash' "$WTOOL_HOME/.wtool/.bashrc" \
    && ok "bashrc 的块 source 的是 env.bash" || bad "bashrc 的块没进汇总"
# 真 source 一遍：变量真的出来了才算数
_got=$(env -i HOME="$WTOOL_HOME" sh -c '. "$HOME/.wtool/.zshrc"; printf "%s" "${TMUX_MARK:-}"')
check "source 汇总文件后变量真的在" "1" "$_got"

# --------------------------------------------------------------------------
printf '\n== 场景 2：check / repair（只报不改 / 只重建不删除）==\n'
_rc=0
_out=$("$WT" check 2>&1) || _rc=$?
chk "装完 check 干净（退出码 0）" "$_rc" "0"
rm -f "$WTOOL_HOME/.tmux.conf"
_rc=0
_out=$("$WT" check 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "软链被删后 check 报出来（退出码非 0）" || bad "check 没报出来"
case $_out in
    *"不见了"*) ok "说清了是哪条不见了" ;;
    *) bad "没说清" "$_out" ;;
esac
"$WT" repair > "$T/repair.log" 2>&1 || bad "repair 执行" "$(cat "$T/repair.log")"
[ -L "$WTOOL_HOME/.tmux.conf" ] && ok "repair 把软链补回来了" || bad "repair 没补回来"
check "补回来的链指向对" "$WTOOL_HOME/.wtool/.tmux.conf" \
    "$(readlink "$WTOOL_HOME/.tmux.conf" 2>/dev/null)"
# repair 不删除：往 $HOME 放一个自己的文件，repair 之后它还得在
printf 'mine\n' > "$WTOOL_HOME/my-own-file"
"$WT" repair > /dev/null 2>&1
[ -f "$WTOOL_HOME/my-own-file" ] && ok "repair 不删用户的东西" || bad "repair 删了用户的东西"
_rc=0
"$WT" check > /dev/null 2>&1 || _rc=$?
chk "repair 之后 check 又干净了" "$_rc" "0"

# 场景 2b：卸载时**先拆 $HOME 软链，再跑 install.sh --uninstall**
_rc=0
"$WT" uninstall "$P" > "$T/u2b.log" 2>&1 || _rc=$?
chk "uninstall 执行成功" "$_rc" "0"
check "install.sh --uninstall 跑的时候 \$HOME 软链已经拆了" "links-gone" \
    "$(cat "$P/order-uninstall.txt" 2>/dev/null)"
[ -e "$WTOOL_HOME/.tmux.conf" ] && bad "卸载后链还在" || ok "卸载后链没了"

# --------------------------------------------------------------------------
printf '\n== 场景 3：有 build.sh 就必须先有 output/ ==\n'
newhome
mkdir -p "$WTOOL_ROOT"
P2=$(mkproj "editor/buildme" "editor/buildme")
mkdir -p "$P2/scripts"
printf '#!/bin/sh\ntrue\n' > "$P2/scripts/build.sh"
printf 'x\n' > "$P2/x.conf"
cat > "$P2/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="editor/buildme" priority="50">
  <link home="~/.x.conf" wtool="~/.wtool/.x.conf" subproject="x.conf"/>
</wtool>
EOF
git -C "$P2" add -A && git -C "$P2" -c user.name=t -c user.email=t@t commit -qm init

_rc=0
"$WT" install "$P2" > "$T/i3.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "没有 output/ 时 install 拒绝" || bad "没有 output/ 居然装上了"
grep -q 'output/ 是空的' "$T/i3.log" && ok "说清了要先 build/download" \
    || bad "没说清原因" "$(cat "$T/i3.log")"
grep -q 'wtool download' "$T/i3.log" && ok "给了可复制的命令" || bad "没给命令"
mkdir -p "$P2/output"
printf 'built\n' > "$P2/output/out.bin"
"$WT" install "$P2" > "$T/i3b.log" 2>&1 || bad "有 output/ 之后 install 执行" "$(cat "$T/i3b.log")"
[ -L "$WTOOL_HOME/.x.conf" ] && ok "有 output/ 之后就装上了" || bad "有 output/ 也没装上"

# 场景 3c：旧目录名（release/ → output/、publish/ → release/）的迁移提示
#   判据是**形状**：旧 release/ 里是 <os>_<ver>/<层>/，新 release/ 里是 *.zip + dist.json。
#   ⚠️ 两个都在时必须给出**顺序**（先 mv release output 再 mv publish release）——
#   反了会把 publish/ 塞进 release/ 里。提示**只 warn，不改退出码**。
mkdir -p "$P2/publish"; printf 'pkg\n' > "$P2/publish/release.zip"
mkdir -p "$P2/release/ubuntu_22.04/main/payload"
_rc=0
_out=$("$WT" check "$P2" 2>&1) || _rc=$?
case $_out in
    *"mv release output && mv publish release"*)
        ok "两个旧目录都在：给了一条按顺序的命令" ;;
    *) bad "两个旧目录都在时没说顺序" "$_out" ;;
esac
chk "迁移提示不影响 check 的退出码" "$_rc" "0"
rm -rf "$P2/release"
_out=$("$WT" check "$P2" 2>&1) || true
case $_out in
    *"请 mv publish release"*) ok "只有旧 publish/：提示改名" ;;
    *) bad "只有旧 publish/ 时没提示" "$_out" ;;
esac
rm -rf "$P2/publish"; mkdir -p "$P2/release/ubuntu_24.04/main/payload"
_out=$("$WT" check "$P2" 2>&1) || true
case $_out in
    *"请 mv release output"*) ok "只有旧形状 release/：提示改名" ;;
    *) bad "只有旧 release/ 时没提示" "$_out" ;;
esac
# 新形状的 release/（dist.json + 分卷）不该被误报
rm -rf "$P2/release"; mkdir -p "$P2/release"
printf '{}\n' > "$P2/release/dist.json"; printf 'z\n' > "$P2/release/release.zip"
_out=$("$WT" check "$P2" 2>&1) || true
case $_out in
    *"mv release"*) bad "新形状的 release/ 被误报成旧目录" "$_out" ;;
    *) ok "新形状的 release/ 不误报" ;;
esac
rm -rf "$P2/release"

# --------------------------------------------------------------------------
printf '\n== 场景 4：uninstall 先问"还有别人要用吗" ==\n'
newhome
mkdir -p "$WTOOL_ROOT"
A=$(mkproj "a/one" "a/one"); B=$(mkproj "b/two" "b/two")
printf 'a\n' > "$A/shared.conf"; printf 'a\n' > "$A/only-a.conf"
printf 'b\n' > "$B/shared.conf"
cat > "$A/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="a/one" priority="50">
  <link home="~/.shared.conf" wtool="~/.wtool/.shared.conf" subproject="shared.conf"/>
  <link home="~/.only-a.conf" wtool="~/.wtool/.only-a.conf" subproject="only-a.conf"/>
</wtool>
EOF
cat > "$B/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="b/two" priority="60">
  <link home="~/.shared.conf" wtool="~/.wtool/.shared.conf" subproject="shared.conf"/>
</wtool>
EOF
git -C "$A" add -A && git -C "$A" -c user.name=t -c user.email=t@t commit -qm init
git -C "$B" add -A && git -C "$B" -c user.name=t -c user.email=t@t commit -qm init

"$WT" install "$A" > /dev/null 2>&1 || bad "装 A"
[ -L "$WTOOL_HOME/.shared.conf" ] && [ -L "$WTOOL_HOME/.only-a.conf" ] \
    && ok "A 的两条链都在" || bad "A 的链没建全"

# B 只在磁盘上声明（没装）—— 判据就是"磁盘上所有 wtool.xml"
"$WT" uninstall "$A" > "$T/u4.log" 2>&1 || bad "卸 A" "$(cat "$T/u4.log")"
[ -L "$WTOOL_HOME/.shared.conf" ] && ok "别人还要用的链被留下" \
    || bad "把别人还要用的链删了"
[ -e "$WTOOL_HOME/.only-a.conf" ] && bad "没人要的链没删掉" || ok "没人要的链被删掉"
grep -q '保留' "$T/u4.log" && ok "说清了为什么保留" || bad "没说清保留原因"
# 留下之后登记表也该改到 B 名下
if [ -f "$WTOOL_STATE/registry.tsv" ]; then
    check "登记改到 b/two 名下" "b/two" \
        "$(awk -F'\t' -v d="$WTOOL_HOME/.shared.conf" '$1==d{print $2}' "$WTOOL_STATE/registry.tsv")"
fi

# --------------------------------------------------------------------------
printf '\n== 场景 5：~/usr 的生命周期（最后一个项目走了才收）==\n'
newhome
mkdir -p "$WTOOL_ROOT"
C=$(mkproj "c/one" "c/one"); D=$(mkproj "d/two" "d/two")
printf 'x\n' > "$C/C.conf"; printf 'y\n' > "$D/D.conf"
for spec in "c/one C" "d/two D"; do
    set -- $spec
    cat > "$T/ws/$1/wtool.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="$1" priority="50">
  <link home="~/.$2.conf" wtool="~/.wtool/.$2.conf" subproject="$2.conf"/>
</wtool>
EOF
    git -C "$T/ws/$1" add -A && git -C "$T/ws/$1" -c user.name=t -c user.email=t@t commit -qm init
done
# 先放一个"编译产物"在影子 HOME 里：~/usr 收走时**只该删软链**
mkdir -p "$WTOOL_HOME/.wtool/usr/bin"; printf 'bin\n' > "$WTOOL_HOME/.wtool/usr/bin/x"
"$WT" install "$C" > /dev/null 2>&1
"$WT" install "$D" > /dev/null 2>&1
[ -L "$WTOOL_HOME/usr" ] && ok "两个项目时 ~/usr 在" || bad "~/usr 不在"
"$WT" uninstall "$C" > /dev/null 2>&1
[ -L "$WTOOL_HOME/usr" ] && ok "还剩一个项目时 ~/usr 留着" || bad "提前把 ~/usr 收走了"
"$WT" uninstall "$D" > /dev/null 2>&1
[ -e "$WTOOL_HOME/usr" ] && bad "一个项目都不剩了 ~/usr 还在" || ok "最后一个项目走了 ~/usr 也收走"
[ -d "$WTOOL_HOME/.wtool/usr" ] && ok "只删软链，影子 HOME 里的实体不动" \
    || bad "把 ~/.wtool/usr 实体也删了"

# --------------------------------------------------------------------------
printf '\n== 场景 5b：uninstall all（按 state 的账，不按项目表）==\n'
newhome
mkdir -p "$WTOOL_ROOT"
G=$(mkproj "g/one" "g/one"); Hh=$(mkproj "h/two" "h/two")
printf 'g\n' > "$G/G.conf"; printf 'h\n' > "$Hh/H.conf"
cat > "$G/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="g/one" priority="50">
  <link home="~/.G.conf" wtool="~/.wtool/.G.conf" subproject="G.conf"/>
</wtool>
EOF
cat > "$Hh/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="h/two" priority="60">
  <link home="~/.H.conf" wtool="~/.wtool/.H.conf" subproject="H.conf"/>
</wtool>
EOF
git -C "$G" add -A && git -C "$G" -c user.name=t -c user.email=t@t commit -qm init
git -C "$Hh" add -A && git -C "$Hh" -c user.name=t -c user.email=t@t commit -qm init
"$WT" install "$G" > /dev/null 2>&1
"$WT" install "$Hh" > /dev/null 2>&1
# 项目目录先"消失"（模拟仓库被删）：all 照样要能卸掉
mv "$Hh" "$Hh.gone"
"$WT" uninstall all > "$T/ua.log" 2>&1 || bad "uninstall all 执行" "$(cat "$T/ua.log")"
[ -e "$WTOOL_HOME/.G.conf" ] && bad "all 没卸掉 g/one" || ok "uninstall all 卸掉了 g/one"
[ -e "$WTOOL_HOME/.H.conf" ] && bad "all 没卸掉 h/two（项目目录已不在）" \
    || ok "项目目录不在也能卸（靠 state 的账）"
[ -e "$WTOOL_HOME/usr" ] && bad "all 之后 ~/usr 还在" || ok "all 之后 ~/usr 收走了"

# --------------------------------------------------------------------------
printf '\n== 场景 6：kill-self-forever（要逐字确认；删 wtool 的、不删别人的）==\n'
newhome
mkdir -p "$WTOOL_ROOT"
E=$(mkproj "e/one" "e/one")
printf 'e\n' > "$E/e.conf"
cat > "$E/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="e/one" priority="50">
  <zshrc src="env.zsh"/>
  <link home="~/.e.conf" wtool="~/.wtool/.e.conf" subproject="e.conf"/>
</wtool>
EOF
printf 'export E=1\n' > "$E/env.zsh"
git -C "$E" add -A && git -C "$E" -c user.name=t -c user.email=t@t commit -qm init
"$WT" install "$E" > /dev/null 2>&1
mkdir -p "$WTOOL_HOME/.wtool/usr/bin"; printf 'bin\n' > "$WTOOL_HOME/.wtool/usr/bin/e"
printf '不是 wtool 的东西\n' > "$WTOOL_HOME/keepme"

# 确认词不对 → 什么都不做
_rc=0
printf 'yes\n' | "$WT" kill-self-forever > "$T/kill1.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "确认词不对 → 拒绝执行" || bad "确认词不对还执行了"
[ -L "$WTOOL_HOME/.e.conf" ] && ok "拒绝之后什么都没删" || bad "拒绝之后东西没了"
grep -q 'KILL-SELF-FOREVER' "$T/kill1.log" && ok "提示了要输入什么" || bad "没提示确认词"
grep -q '不删' "$T/kill1.log" && ok "列清了不删什么（sudo 装的、别人的）" || bad "没说清不删什么"

_rc=0
"$WT" kill-self-forever --yes > "$T/kill2.log" 2>&1 || _rc=$?
chk "--yes 执行成功" "$_rc" "0"
[ -e "$WTOOL_HOME/.wtool" ] && bad "~/.wtool 还在" || ok "~/.wtool 删干净了"
[ -e "$WTOOL_HOME/.e.conf" ] && bad "软链还在" || ok "$HOME 里的软链删干净了"
[ -e "$WTOOL_STATE" ] && bad "state 还在" || ok "state 也删了"
grep -q 'wtool' "$WTOOL_HOME/.zshrc" && bad "rc 里的 loader 块还在" || ok "rc 里的 loader 块剥掉了"
check "rc 回到用户原来的内容" \
    "$(printf '# 用户自己的 zshrc\nsetopt auto_cd\nexport MY_STUFF=1')" \
    "$(cat "$WTOOL_HOME/.zshrc")"
[ -f "$WTOOL_HOME/keepme" ] && ok "不是 wtool 的东西一个字节没动" || bad "删了不属于它的文件"

# --------------------------------------------------------------------------
printf '\n== 场景 7：旧标签仍然认，但要警告（过渡期）==\n'
newhome
mkdir -p "$WTOOL_ROOT"
F=$(mkproj "f/legacy" "f/legacy")
printf 'f\n' > "$F/f.conf"
cat > "$F/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="f/legacy" priority="50">
  <env src="env.zsh" shells="zsh"/>
  <link src="f.conf" dest=".f.conf"/>
</wtool>
EOF
printf 'export F=1\n' > "$F/env.zsh"
git -C "$F" add -A && git -C "$F" -c user.name=t -c user.email=t@t commit -qm init

_rc=0
_v=$("$WT" validate "$F" 2>&1) || _rc=$?
chk "旧标签仍能通过校验" "$_rc" "0"
case $_v in
    *"旧写法"*) ok "validate 提示了旧写法该改" ;;
    *) bad "validate 没提示旧写法" "$_v" ;;
esac
"$WT" install "$F" > /dev/null 2>&1 || bad "旧标签的清单装不上"
[ -L "$WTOOL_HOME/.f.conf" ] && ok "旧标签照样铺出软链" || bad "旧标签没铺出软链"
[ -L "$WTOOL_HOME/.wtool/.f.conf" ] && ok "旧标签也走两跳（中间那一跳在）" \
    || bad "旧标签没走两跳"

# --------------------------------------------------------------------------
printf '\n== 场景 8：删掉的命令与改名的命令 ==\n'
for _dead in env list table; do
    _m=$("$WT" $_dead 2>&1 || true)
    case $_m in
        *已经删掉*) ok "$_dead 提示已删掉" ;;
        *) bad "$_dead 没提示已删掉" "$_m" ;;
    esac
done
_m=$("$WT" provision "$F" 2>&1 || true)
case $_m in
    *sudo-install*) ok "provision 指向了 sudo-install" ;;
    *) bad "provision 没指向新名字" "$_m" ;;
esac
_m=$("$WT" sudo-install "$F" --with-system 2>&1 || true)
case $_m in
    *已经删掉*) ok "sudo-install --with-system 提示已删掉" ;;
    *) bad "--with-system 没提示" "$_m" ;;
esac
_m=$("$WT" bootstrap --with-system 2>&1 || true)
case $_m in
    *sudo-bootstrap*) ok "bootstrap --with-system 指向 sudo-bootstrap" ;;
    *) bad "bootstrap --with-system 没指向新命令" "$_m" ;;
esac

# --------------------------------------------------------------------------
printf '\n== 场景 9：<build kind="local|docker"/>（ADR-025）==\n'
#   kind 决定两件事：这台机器行不行（没 docker 直接指路 download-release）、
#   output/ 是什么形状（release.json 的 targets[] 跟着它走）。
newhome
mkdir -p "$WTOOL_ROOT"

mkbuildproj() {   # <相对路径> <id> <build 标签行>
    _d=$(mkproj "$1" "$2")
    mkdir -p "$_d/scripts"
    cat > "$_d/scripts/build.sh" <<'BEOF'
#!/bin/sh
echo "ran" > "$WTOOL_PROJECT_DIR/build-ran.txt"
mkdir -p "$WTOOL_PROJECT_DIR/output/$WTOOL_BUILD_LAYER"
printf 'x\n' > "$WTOOL_PROJECT_DIR/output/$WTOOL_BUILD_LAYER/out.bin"
BEOF
    chmod +x "$_d/scripts/build.sh"
    printf '%s\n' "$3" > "$_d/buildline"
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<wtool schema="1" id="%s" priority="50">\n' "$2"
        cat "$_d/buildline"
        printf '</wtool>\n'
    } > "$_d/wtool.xml"
    rm -f "$_d/buildline"
    echo "$_d"
}

# ① 非法 kind：validate 必须拒绝（顺带证明 <build> 不再是"未知元素" —— BL-22）
PD=$(mkbuildproj "editor/dockerproj" "editor/dockerproj" '<build kind="podman"/>')
_rc=0
_out=$("$WT" validate "$PD" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "<build kind=\"podman\"> 被 validate 拒绝" || bad "非法 kind 居然过了"
case $_out in
    *"只能是 local / docker"*) ok "报错说清了合法值" ;;
    *) bad "没说清合法值" "$_out" ;;
esac
# 顺带：<build> 本身是认识的标签了（BL-22 的症状是 error: 未知元素 <build>）
case $_out in
    *"未知元素"*) bad "validate 仍把 <build> 当未知元素（BL-22 回来了）" "$_out" ;;
    *) ok "<build> 不再是未知元素（BL-22）" ;;
esac
# 清单坏了的时候 build **不许猜**：解析失败 = 停下来，不能当成"大概是 local"就地开编
_rc=0
_out=$(WTOOL_DOCKER=/nonexistent/wtool-docker "$WT" build "$PD" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "清单坏了时 build 拒绝跑" || bad "清单坏了也照编（kind 落回默认值）"
[ -f "$PD/build-ran.txt" ] && bad "清单坏了 build.sh 还是跑了" || ok "清单坏了 build.sh 没跑"
case $_out in
    *"wtool.xml 有问题"*) ok "指了路（先 wtool validate）" ;;
    *) bad "没说清单有问题" "$_out" ;;
esac

# ② kind=docker + 没有 docker：拒绝、说原因、指路 download-release，**脚本不许跑**
WTB=$(mkbuildproj "editor/dockerproj" "editor/dockerproj" '<build kind="docker"/>')
export WTOOL_BUILD_LAYER=main
_rc=0
_out=$(WTOOL_DOCKER=/nonexistent/wtool-docker "$WT" build "$WTB" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "没 docker 时 build 退出码非 0（不当成成功）" || bad "没 docker 也报成功"
case $_out in
    *docker*) ok "说清了缺的是 docker" ;;
    *) bad "没说缺 docker" "$_out" ;;
esac
case $_out in
    *"download-release"*) ok "指了路：download-release" ;;
    *) bad "没指路下载" "$_out" ;;
esac
[ -f "$WTB/build-ran.txt" ] && bad "build.sh 居然跑了（白等一场）" || ok "build.sh 没跑（动手之前就拦住）"

# ③ 同一台机器上 kind=local（显式写）照跑
PL=$(mkbuildproj "editor/localproj" "editor/localproj" '<build kind="local" min-cores="1" min-mem="1" min-disk="1"/>')
_rc=0
_out=$(WTOOL_DOCKER=/nonexistent/wtool-docker "$WT" build "$PL" 2>&1) || _rc=$?
chk "kind=local：没有 docker 也编" "$_rc" "0"
[ -f "$PL/build-ran.txt" ] && ok "build.sh 跑了" || bad "local 项目没跑起来" "$_out"
chk "<build> 里的 min-* 是认识的（BL-22：不再报未知元素）" \
    "$("$WT" validate "$PL" >/dev/null 2>&1 && echo ok || echo bad)" "ok"

# ④ 不写 <build> = local（默认），也不要求 docker
PN=$(mkbuildproj "editor/nobuildtag" "editor/nobuildtag" '<!-- 没有 <build> -->')
_rc=0
WTOOL_DOCKER=/nonexistent/wtool-docker "$WT" build "$PN" >/dev/null 2>&1 || _rc=$?
chk "不写 <build> 时默认 local，不要求 docker" "$_rc" "0"

# ⑤ 形状由声明决定：targets[] 的来源
chk "local 项目的 targets 是空的（不把层名当 target）" "" \
    "$(python3 "$boot/lib/wtool_plan.py" release-targets "$PL")"
mkdir -p "$WTB/output/ubuntu_22.04/main" "$WTB/output/ubuntu_24.04/main"
chk "docker 项目的 targets 就是 output/<os>_<ver>/ 的名字" "ubuntu_22.04,ubuntu_24.04" \
    "$(python3 "$boot/lib/wtool_plan.py" release-targets "$WTB")"
mkdir -p "$PL/output/main" "$PL/output/lang-lua"      # local：层名不是 target
chk "local 项目就算 output/ 里有多个目录，targets 还是空" "" \
    "$(python3 "$boot/lib/wtool_plan.py" release-targets "$PL")"

# --------------------------------------------------------------------------
printf '\n== 场景 9b：check 两个 shell 的汇总文件都查（BL-24）==\n'
#   生成那一侧两个 shell 都做了（render_env + _loader_block），
#   但 check 原来只查 ~/.wtool/.zshrc —— .bashrc 被误删时它一声不吭，
#   而 bash 用户的环境变量就静默失效了（最难查的半装状态）。
newhome
mkdir -p "$WTOOL_ROOT"
PB=$(mkproj "terminal/bashonly" "terminal/bashonly")
printf 'export BASH_ONLY=1\n' > "$PB/env.bash"
printf 'export BASH_ONLY=1\n' > "$PB/env.zsh"
cat > "$PB/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="terminal/bashonly" priority="50">
  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>
</wtool>
EOF
git -C "$PB" add -A && git -C "$PB" -c user.name=t -c user.email=t@t commit -qm init
"$WT" install "$PB" >/dev/null 2>&1 || bad "装了却失败" "$(cat "$T/../x" 2>/dev/null)"
_out=$("$WT" check "$PB" 2>&1) || true
case $_out in
    *bashrc*) bad "两个汇总文件都在时就报 bashrc 有问题" "$_out" ;;
    *) ok "两个汇总文件都在时 check 不报" ;;
esac
rm -f "$WTOOL_HOME/.wtool/.bashrc"
_rc=0
_out=$("$WT" check "$PB" 2>&1) || _rc=$?
case $_out in
    *".wtool/.bashrc 不见了"*) ok "★删掉 ~/.wtool/.bashrc 之后 check 报出来（BL-24 修好）" ;;
    *) bad "删了 .bashrc check 还是不吭声" "$_out" ;;
esac
[ "$_rc" != 0 ] && ok "check 退出码非 0" || bad "报了问题却退 0"

# --------------------------------------------------------------------------
printf '\n== 场景 10：install 认项目 id 和 all（需求 2）==\n'
#   需求 2 的形状是 `wtool [build|install|publish|download] all`。
#   build/download 早就有 all，install 只有 bootstrap 那条名字 —— 2026-09-28 补上。
newhome
# 自己一棵新的工作区根：前面的场景在同一棵树里留了一堆项目，
# `install all` 会把它们的软链冲突一起扫出来（那是别的场景要验的事）
export WTOOL_ROOT="$T/ws10"
mkdir -p "$WTOOL_ROOT/terminal/instid"
PI="$WTOOL_ROOT/terminal/instid"
git -C "$PI" init -q
mkdir -p "$PI/output" "$PI/scripts"
printf 'hello\n' > "$PI/out.conf"
printf 'built\n' > "$PI/output/out.bin"
cat > "$PI/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="terminal/instid" priority="50">
  <link home="~/.instid.conf" wtool="~/.wtool/.instid.conf" subproject="out.conf"/>
</wtool>
EOF
git -C "$PI" add -A && git -C "$PI" -c user.name=t -c user.email=t@t commit -qm init

# ① 按 id 装（build / download-release / publish-release 都认 id，install 以前只认目录）
_rc=0
_out=$("$WT" install terminal/instid 2>&1) || _rc=$?
chk "install 认项目 id" "$_rc" "0"
[ -L "$WTOOL_HOME/.instid.conf" ] && ok "按 id 真装上了" || bad "按 id 没装上" "$_out"
"$WT" uninstall --id terminal/instid >/dev/null 2>&1 || true
[ -L "$WTOOL_HOME/.instid.conf" ] && bad "uninstall --id 没撤掉" || ok "uninstall --id 撤掉了"

# 不带 --id 的裸 id 也要认（install 认了，uninstall 不认就会死在 cd 上）
"$WT" install terminal/instid >/dev/null 2>&1 || true
_rc=0
_out=$("$WT" uninstall terminal/instid 2>&1) || _rc=$?
chk "uninstall 也认裸项目 id" "$_rc" "0"
[ -e "$WTOOL_HOME/.instid.conf" ] && bad "裸 id 没撤掉" || ok "裸 id 撤掉了"

# ② install all（= wtool bootstrap：装所有"不需要你决策"的项目）
_rc=0
_out=$("$WT" install all 2>&1) || _rc=$?
chk "install all 退出码 0" "$_rc" "0"
[ -L "$WTOOL_HOME/.instid.conf" ] && ok "install all 把项目装上了" || bad "install all 没装上" "$_out"
# dry-run 要在一个**干净的家目录**里验：刚装过的话"没有需要变更的内容"，
# 什么都不会打印（那条断言会假失败）
newhome
export WTOOL_ROOT="$T/ws10"
_rc=0
_out=$("$WT" install all --dry-run 2>&1) || _rc=$?
chk "install all --dry-run 退出码 0" "$_rc" "0"
case $_out in
    *"[dry-run]"*) ok "install all 也吃 --dry-run（打了计划）" ;;
    *) bad "install all --dry-run 没生效" "$_out" ;;
esac
[ -e "$WTOOL_HOME/.instid.conf" ] && bad "dry-run 居然真装了" || ok "dry-run 一个字节没动"

# --------------------------------------------------------------------------
printf '\n== 场景 11：install --prune 清掉"清单里已经删掉"的软链（BL-15）==\n'
#   症状：从 wtool.xml 里删掉一条 <link> 之后重装，旧软链还留在磁盘上
#   （journal 里也还在），一直到 uninstall 才清。--prune 以 journal 为基准收掉它们。
#   判据必须是 **journal**（"我做过什么"）而不是扫磁盘 —— 扫磁盘会删掉用户自己的东西。
newhome
mkdir -p "$WTOOL_ROOT"
PP=$(mkproj "terminal/pruneproj" "terminal/pruneproj")
mkdir -p "$PP/scripts"
printf 'a\n' > "$PP/a.conf"
printf 'b\n' > "$PP/b.conf"
printf 'x\n' > "$PP/x.conf"
prune_manifest() {   # <要写进去的 link 行…>：没给就写"只有 a 那一行"
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<wtool schema="1" id="terminal/pruneproj" priority="50">\n'
        printf '%s\n' "$@"
        printf '</wtool>\n'
    } > "$PP/wtool.xml"
    git -C "$PP" add -A
    git -C "$PP" -c user.name=t -c user.email=t@t commit -qm "manifest"
}
prune_manifest \
  '<link home="~/.prune-a.conf" wtool="~/.wtool/.prune-a.conf" subproject="a.conf"/>' \
  '<link home="~/.prune-b.conf" wtool="~/.wtool/.prune-b.conf" subproject="b.conf"/>' \
  '<link home="~/.prune-dir/x.conf" wtool="~/.wtool/.prune-x.conf" subproject="x.conf"/>'
"$WT" install "$PP" >/dev/null 2>&1 || bad "第一遍没装上（后面的断言都不成立）"
{ [ -L "$WTOOL_HOME/.prune-a.conf" ] && [ -L "$WTOOL_HOME/.prune-b.conf" ] \
  && [ -L "$WTOOL_HOME/.prune-dir/x.conf" ]; } \
    && ok "三条软链都建了" || bad "第一遍没建全"
[ -d "$WTOOL_HOME/.prune-dir" ] && ok "嵌套落点的父目录是引擎建的（--prune 要能收走）" \
    || bad "父目录没建"
# 用户自己（不是 wtool）放的一条软链：--prune 一个字节都不许碰
ln -s /etc/hostname "$WTOOL_HOME/.prune-user.conf"

# 清单里删掉 b，重装
prune_manifest '<link home="~/.prune-a.conf" wtool="~/.wtool/.prune-a.conf" subproject="a.conf"/>'
"$WT" install "$PP" >/dev/null 2>&1 || bad "删掉 b 之后重装失败"
[ -L "$WTOOL_HOME/.prune-b.conf" ] && ok "不带 --prune 时旧软链留着（BL-15 的症状，故意的）" \
    || bad "什么都没做旧链就没了（那这条不是可选项了）"

# ① --dry-run 只说不做
"$WT" install "$PP" --prune --dry-run >/dev/null 2>&1 || bad "--prune --dry-run 失败"
[ -L "$WTOOL_HOME/.prune-b.conf" ] && ok "--prune --dry-run 一个字节没动" || bad "dry-run 居然真删了"

# ② --prune 真删，而且只删该删的
_rc=0
_out=$("$WT" install "$PP" --prune 2>&1) || _rc=$?
chk "--prune 退出码 0" "$_rc" "0"
[ -L "$WTOOL_HOME/.prune-b.conf" ] && bad "--prune 没删掉旧软链" "$_out" \
    || ok "--prune 删掉了旧软链（清单里没有 b 了）"
[ -L "$WTOOL_HOME/.prune-a.conf" ] && ok "清单里还有的那条留着" || bad "--prune 连在册的也删了"
[ -L "$WTOOL_HOME/.prune-user.conf" ] && ok "不是我们建的软链不碰" || bad "--prune 删了用户自己的软链"
[ -e "$WTOOL_HOME/.prune-dir" ] && bad "嵌套落点的空目录没收走（prune-dir 没跑）" \
    || ok "嵌套落点的空目录也收走了"
grep -q 'prune-b' "$WTOOL_STATE/terminal/pruneproj/journal.tsv" 2>/dev/null \
    && bad "账还留在 journal 里（下次 --prune 会再删一遍）" || ok "journal 里那条账销掉了"
grep -q 'prune-b' "$WTOOL_STATE/registry.tsv" 2>/dev/null \
    && bad "registry 里还占着落点（别的项目想用会撞冲突）" || ok "registry 里那条清了"

# ③ 幂等：再来一次不报错、也不动别的东西
_rc=0
_out=$("$WT" install "$PP" --prune 2>&1) || _rc=$?
chk "重复 --prune 退出码 0" "$_rc" "0"
[ -L "$WTOOL_HOME/.prune-a.conf" ] && [ -L "$WTOOL_HOME/.prune-user.conf" ] \
    && ok "重复 --prune 没伤到别人" || bad "重复 --prune 删多了"

# ④ 刹车：落点已经归了**另一个项目**（链接搬了家）→ 不删，留给那个项目
PQ=$(mkproj "terminal/pruneproj2" "terminal/pruneproj2")
mkdir -p "$PQ/scripts"
printf 'c\n' > "$PQ/c.conf"
cat > "$PQ/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="terminal/pruneproj2" priority="50">
  <link home="~/.prune-a.conf" wtool="~/.wtool/.prune-a2.conf" subproject="c.conf"/>
</wtool>
EOF
git -C "$PQ" add -A && git -C "$PQ" -c user.name=t -c user.email=t@t commit -qm init
"$WT" install "$PQ" --force >/dev/null 2>&1 || bad "第二个项目（同一个落点）没装上"
prune_manifest '<link home="~/.stay.conf" wtool="~/.wtool/.stay.conf" subproject="a.conf"/>'
"$WT" install "$PP" --prune >/dev/null 2>&1 || bad "第二个项目装上之后 --prune 失败"
[ -L "$WTOOL_HOME/.prune-a.conf" ] && ok "落点归了别的项目时不越权（链接留着）" \
    || bad "--prune 删了别的项目正在用的软链"

# --------------------------------------------------------------------------
# ③ 找不到时给的是能看懂的错，并且提一句怎么列出全部
_out=$("$WT" install nosuch-project 2>&1) || true
case $_out in
    *"项目目录不存在"*"wtool 裸跑看全部"*) ok "找不到项目时错误信息指了路" ;;
    *) bad "错误信息不好懂" "$_out" ;;
esac

# --------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'contract_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
