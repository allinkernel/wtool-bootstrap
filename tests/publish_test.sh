#!/bin/sh
# publish_test.sh —— 测 wtool publish 的非 docker 部分
#
# 全程用打桩的 gh：不碰网络、不碰真 $WTOOL_STATE、不碰 $HOME。
# 验证点：
#   1. 源码包第一层固定是 wtool/，解压后路径与 repo sync 一致
#   2. 包里不含 .git
#   3. 包里带 .wtool-dist/<id>.json（解压副本免 --force + 有 head 可溯源）
#   4. kind="none" 的项目（nvim，第三方上游仓）不被发布
#   5. kind="script" 的项目调项目内脚本，脚本产出啥就传啥
#   6. 项目的 remote 名字是 github（repo 客户端）时也能找到目标仓
#   7. 本地记录 publish.tsv
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
WS=$(cd -- "$here/../.." && pwd)
WT="$WS/bootstrap/wtool.sh"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3] 实际 [$2]）"; fi; }
chkn() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1（不该是 [$3]）"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-pubtest.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/state" "$T/out"
cat > "$T/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$1 \$2" in
    "repo view")    echo "ADMIN"; exit 0 ;;   # 假装有所有仓的写权限
    "release view") exit 1 ;;                 # 假装 release 还不存在
    *)              exit 0 ;;
esac
EOF
chmod +x "$T/bin/gh"
: > "$T/gh.log"

# 安静一点：python 别刷 ResourceWarning，解包别刷 tar 的错误
py() { python3 -W ignore "$@"; }
# 按文件内容选解压器，别假设扩展名
untar() {
    case $(file -b -- "$1") in
        *Zstandard*) zstd -dc -- "$1" | tar -xf - -C "$2" ;;
        *gzip*)      gzip -dc -- "$1" | tar -xf - -C "$2" ;;
        *)           tar -xf "$1" -C "$2" ;;
    esac
}

# 把 PWD 挪出工作区，避免相对路径干扰
cd "$T"

echo "== 1. 源码发布：terminal/tmux =="
PATH="$T/bin:$PATH" WTOOL_STATE="$T/state" \
    "$WT" publish terminal/tmux --out="$T/out" > "$T/log1" 2>&1 || {
    bad "publish 退出码非 0"; sed 's/^/     /' "$T/log1"; }

PKG=$(ls "$T/out"/out-0/terminal-tmux-*.tar.* 2>/dev/null | head -1)
if [ -f "$PKG" ]; then ok "产出了源码包 $(basename "$PKG")"; else bad "没产出源码包"; fi

if [ -f "$PKG" ]; then
    LIST=$(case $(file -b -- "$PKG") in
               *Zstandard*) zstd -dc -- "$PKG" | tar -tf - ;;
               *gzip*)      gzip -dc -- "$PKG" | tar -tf - ;;
               *)           tar -tf "$PKG" ;;
           esac)
    echo "$LIST" > "$T/list.txt"

    # 1) 第一层固定 wtool/
    if printf '%s\n' "$LIST" | grep -qv '^wtool/'; then
        bad "有成员不在 wtool/ 下"; printf '%s\n' "$LIST" | grep -v '^wtool/' | head -3 | sed 's/^/     /'
    else
        ok "所有成员都在 wtool/ 前缀下"
    fi

    # 2) 项目本身在正确位置
    if printf '%s\n' "$LIST" | grep -q '^wtool/terminal/tmux/install.sh$'; then
        ok "wtool/terminal/tmux/install.sh 在（解压后路径 == repo sync）"
    else
        bad "缺少 wtool/terminal/tmux/install.sh"
    fi

    # 3) 不含 .git
    chk "不含 .git 成员" "$(printf '%s\n' "$LIST" | grep -c '\.git' || true)" "0"

    # 4) 带发布标记
    MARK=$(printf '%s\n' "$LIST" | grep '^wtool/\.wtool-dist/' || true)
    chk "带一个 .wtool-dist 标记" "$(printf '%s\n' "$MARK" | grep -c . || true)" "1"
    mkdir -p "$T/out/x"
    untar "$PKG" "$T/out/x"
    MJ="$T/out/x/wtool/.wtool-dist/terminal-tmux.json"
    if [ -f "$MJ" ]; then
        ok "标记文件能解出来"
        chk "标记里 view=release" "$(py -c 'import json,sys;print(json.load(open(sys.argv[1]))["view"])' "$MJ")" "release"
        REAL=$(git -C "$WS/terminal/tmux" rev-parse HEAD)
        chk "标记里的 commit 是项目 HEAD" "$(py -c 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "$MJ")" "$REAL"
        chk "标记里 layout 指向 wtool/terminal/tmux" "$(py -c 'import json,sys;print(json.load(open(sys.argv[1]))["layout"])' "$MJ")" "wtool/terminal/tmux"
    else
        bad "标记文件解不出来: $MJ"
    fi
fi

echo "== 2. gh 调用 =="
grep -q 'release create snapshot-.* --repo allinkernel/wtool-tmux-config' "$T/gh.log" \
    && ok "对项目自己的仓建了 release" || { bad "没建 release"; sed 's/^/     /' "$T/gh.log"; }
grep -q 'release upload .* --repo allinkernel/wtool-tmux-config' "$T/gh.log" \
    && ok "上传到同一个仓" || bad "没上传"
grep -qE '\.tar\.(zst|gz)' "$T/gh.log" && ok "传的是 tar 包" || bad "传的不是 tar 包"

echo "== 3. 本地记录 =="
REC="$T/state/terminal/tmux/publish.tsv"
if [ -f "$REC" ]; then
    ok "写了 publish.tsv"
    chk "记录了目标仓" "$(awk -F'\t' '{print $2}' "$REC")" "allinkernel/wtool-tmux-config"
else
    bad "没有 publish.tsv"
fi

echo "== 4. kind=none 不发布（nvim 是第三方上游仓）=="
: > "$T/gh.log"
PATH="$T/bin:$PATH" WTOOL_STATE="$T/state" \
    "$WT" publish nvim --out="$T/out" > "$T/log4" 2>&1 || true
chk "对 nvim 没有任何 gh 调用" "$(grep -c . "$T/gh.log" || true)" "0"
grep -q '声明为不发布' "$T/log4" && ok "明确说了不发布" || bad "没说清为什么不发"

echo "== 5. kind=script：调项目内脚本，脚本产出啥传啥 =="
# 造一个孤立的工作区，里面一个 script 型项目。
# 用 <publish to="..."> 指定目标仓，顺带验证 to= 能顶掉 remote 解析。
FS="$T/ws"
mkdir -p "$FS/scripted"
cat > "$FS/scripted/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="scripted" priority="10">
  <publish kind="script" script="publish.sh" to="fakeowner/scripted-release"/>
</wtool>
EOF
cat > "$FS/scripted/publish.sh" <<'EOF'
set -eu
echo "project=$WTOOL_PUBLISH_PROJECT repo=$WTOOL_PUBLISH_REPO tag=$WTOOL_PUBLISH_TAG"
echo "root=$WTOOL_PUBLISH_ROOT ws=$WTOOL_PUBLISH_WS"
echo "hello" > "$WTOOL_PUBLISH_OUT/one.bin"
echo "world" > "$WTOOL_PUBLISH_OUT/two.bin"
EOF
mkdir -p "$FS/scripted/.git"
git -C "$FS/scripted" init -q 2>/dev/null || true
: > "$T/gh.log"
PATH="$T/bin:$PATH" WTOOL_ROOT="$FS" WTOOL_STATE="$T/state2" \
    "$WT" publish scripted --out="$T/out2" > "$T/log5" 2>&1 || {
    bad "script 型 publish 失败"; sed 's/^/     /' "$T/log5"; }
UPLOADLINE=$(grep 'release upload' "$T/gh.log" || true)
case $UPLOADLINE in
    *one.bin*two.bin*|*two.bin*one.bin*) ok "脚本产出的两个文件都被上传" ;;
    *) bad "脚本产出没上传（upload 行: ${UPLOADLINE:-无}）" ;;
esac
grep -q 'one.bin' "$T/gh.log" && grep -q 'two.bin' "$T/gh.log" \
    && ok "两个产出文件都在 upload 里" || { bad "产出文件没上传"; sed 's/^/     /' "$T/gh.log"; }
grep -q "repo=scripted" "$T/log5" && bad "目标仓没解析出来（应报无 remote）" || true
grep -q "project=scripted" "$T/log5" && ok "脚本拿到了 WTOOL_PUBLISH_PROJECT" || true
grep -q "root=$FS/scripted" "$T/log5" && ok "脚本拿到了 WTOOL_PUBLISH_ROOT" || true

echo "== 6. 回归：脚本读 stdin 不能吃掉后面的项目 =="
# 曾经的真 bug：publish.sh 里的交互式 read 会从引擎的 while 循环里偷走一行，
# 表现是清单里下一个项目被静默跳过（实测吞掉了 astronvim_v5_config）。
# 修法：清单走 fd 3，脚本 stdin 给 /dev/null。
FS2="$T/ws2"
mkdir -p "$FS2/aaa-script" "$FS2/zzz-after"
cat > "$FS2/aaa-script/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="aaa-script" priority="10">
  <publish kind="script" script="publish.sh" to="fakeowner/aaa"/>
</wtool>
EOF
cat > "$FS2/aaa-script/publish.sh" <<'EOF'
set -eu
# 模拟"问用户一个问题"的脚本：没有 /dev/null 的话这里会把引擎的清单读走
printf '选择: '
read -r answer || answer=""
echo "拿到 [$answer]" > "$WTOOL_PUBLISH_OUT/answer.txt"
EOF
cat > "$FS2/zzz-after/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="zzz-after" priority="20">
  <publish kind="source" to="fakeowner/zzz"/>
</wtool>
EOF
# 得把 wtool.xml 也提交掉：工作区有未提交改动时源码发布会拒绝，
# 那样就分不清"被 stdin 偷走了"和"被脏检查挡下了"
git -C "$FS2/zzz-after" init -q 2>/dev/null || true
git -C "$FS2/zzz-after" add -A 2>/dev/null || true
git -C "$FS2/zzz-after" -c user.name=t -c user.email=t@t commit -q -m init 2>/dev/null || true

: > "$T/gh.log"
PATH="$T/bin:$PATH" WTOOL_ROOT="$FS2" WTOOL_STATE="$T/state6" \
    "$WT" publish --out="$T/out6" > "$T/log6" 2>&1 || true
_scripted=$(grep -c '^wtool: ── aaa-script ' "$T/log6" || true)
_after=$(grep -c '^wtool: ── zzz-after ' "$T/log6" || true)
chk "脚本型项目被处理了" "$_scripted" "1"
chk "★它后面的项目没有被吞掉" "$_after" "1"
if grep -q 'zzz-after' "$T/gh.log"; then
    ok "后面的项目确实发布了（gh 收到了它的仓）"
else
    bad "后面的项目没发布——stdin 又被偷了"
fi
chk "脚本拿到的是空输入（不是清单行）" \
    "$(cat "$T/out6/out-0/answer.txt" 2>/dev/null | sed 's/拿到 \[//;s/\]//')" ""

echo "== 7. 第三方仓必须被挡住（而不是静默中断整个发布）=="
# 曾经的真 bug：_perm=$(wt_publish_can_push ...) 在 set -e 下，
# 命令替换返回非 0 会让脚本静默退出——保护逻辑从没生效，整个发布却无声中断。
# 之前的测试打桩一律返回 ADMIN，正好绕过了这条路径。
FS3="$T/ws3"
mkdir -p "$FS3/third"
cat > "$FS3/third/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="third" priority="10">
  <publish to="neovim/neovim"/>
</wtool>
EOF
git -C "$FS3/third" init -q 2>/dev/null || true
git -C "$FS3/third" add -A 2>/dev/null || true
git -C "$FS3/third" -c user.name=t -c user.email=t@t commit -q -m init 2>/dev/null || true

# 打桩：viewerPermission 返回 READ（只读）
mkdir -p "$T/bin-read"
cat > "$T/bin-read/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$1 \$2" in
    "repo view") echo "READ"; exit 0 ;;
    *)           exit 0 ;;
esac
EOF
chmod +x "$T/bin-read/gh"
: > "$T/gh.log"
_rc=0
PATH="$T/bin-read:$PATH" WTOOL_ROOT="$FS3" WTOOL_STATE="$T/state7" \
    "$WT" publish --out="$T/out7" > "$T/log7" 2>&1 || _rc=$?
chk "退出码是 0（不是被 set -e 静默打断）" "$_rc" "0"
grep -q '没有 neovim/neovim 的写权限' "$T/log7" \
    && ok "明确报了没有写权限" || { bad "没报权限问题"; sed 's/^/     /' "$T/log7"; }
grep -q 'kind=\"none\"' "$T/log7" && ok "给了怎么改的建议" || bad "没给建议"
chk "没有产生任何 gh 写操作" "$(grep -cE 'release (create|upload)' "$T/gh.log" || true)" "0"

echo "== 8. release view 失败但 release 其实存在 → 复用，不硬失败 =="
# view 失败 ≠ 不存在：网络抖一下或 API 最终一致性都会让 view 报错，
# 这时 create 会撞 422 already exists。硬失败会让整个发布停在一个
# 早就建好的 release 上（实测在 shell/zsh 上撞过）。
mkdir -p "$T/bin-race"
cat > "$T/bin-race/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
    "repo view")      echo "ADMIN"; exit 0 ;;
    "release view")   exit 1 ;;
    "release create") echo "HTTP 422: Release.tag_name already exists" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/bin-race/gh"
FS4="$T/ws4"; mkdir -p "$FS4/racy"
cat > "$FS4/racy/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="racy" priority="10">
  <publish to="fakeowner/racy"/>
</wtool>
EOF
git -C "$FS4/racy" init -q 2>/dev/null || true
git -C "$FS4/racy" add -A 2>/dev/null || true
git -C "$FS4/racy" -c user.name=t -c user.email=t@t commit -q -m init 2>/dev/null || true
_rc=0
PATH="$T/bin-race:$PATH" WTOOL_ROOT="$FS4" WTOOL_STATE="$T/state8" \
    "$WT" publish --out="$T/out8" > "$T/log8" 2>&1 || _rc=$?
chk "退出码是 0" "$_rc" "0"
grep -q '已经存在' "$T/log8" && ok "认 create 的 already exists，直接复用" \
    || { bad "没有复用已存在的 release"; sed 's/^/     /' "$T/log8"; }
grep -q '创建 release 失败' "$T/log8" && bad "误判成创建失败" || ok "没有误报创建失败"
grep -q '上传' "$T/log8" && ok "复用之后照常上传资产" || bad "复用后没上传"

# 场景 8b：view 只是抖了一下，create 说已存在，之后 view 恢复
mkdir -p "$T/bin-flaky"
cat > "$T/bin-flaky/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
    "repo view")      echo "ADMIN"; exit 0 ;;
    "release view")   exit 1 ;;
    "release create") echo "HTTP 422: Release.tag_name already exists" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/bin-flaky/gh"
_rc=0
PATH="$T/bin-flaky:$PATH" WTOOL_ROOT="$FS4" WTOOL_STATE="$T/state8b" \
    "$WT" publish --out="$T/out8b" > "$T/log8b" 2>&1 || _rc=$?
chk "view 持续故障 + create 报已存在 → 也能复用" "$_rc" "0"

echo "== 9. ★相对符号链接不能在包里被改写（回归）=="
# 曾经的真 bug：--transform 默认连**符号链接的指向**一起改写，于是包里变成
#   themes/foo.zsh-theme -> wtool/bar.zsh-theme
# 解压出来全是断链。oh-my-zsh 里 themes/*.zsh-theme 和
# plugins/*/*.plugin.zsh 都中招了。
# 只在真去下载发布包解压时才暴露——光看 tar -tf 是看不出来的，
# 所以这条测试必须真解压再检查软链。
FS5="$T/ws5"; mkdir -p "$FS5/lnk/themes" "$FS5/lnk/plugins/pp"
printf 'colours\n' > "$FS5/lnk/themes/real.zsh-theme"
ln -sf real.zsh-theme "$FS5/lnk/themes/alias.zsh-theme"
printf 'plug\n' > "$FS5/lnk/plugins/pp/real.zsh"
ln -sf real.zsh "$FS5/lnk/plugins/pp/alias.plugin.zsh"
ln -sf /etc/hostname "$FS5/lnk/abs-link"
cat > "$FS5/lnk/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="lnk" priority="10">
  <publish kind="source" to="fakeowner/lnk"/>
</wtool>
EOF
git -C "$FS5/lnk" init -q 2>/dev/null || true
git -C "$FS5/lnk" add -A 2>/dev/null || true
git -C "$FS5/lnk" -c user.name=t -c user.email=t@t commit -q -m init 2>/dev/null || true

_rc=0
PATH="$T/bin:$PATH" WTOOL_ROOT="$FS5" WTOOL_STATE="$T/state9" \
    "$WT" publish lnk --out="$T/out9" > "$T/log9" 2>&1 || _rc=$?
chk "发布成功" "$_rc" "0"

LPKG=$(ls "$T/out9"/out-0/*.tar.* 2>/dev/null | head -1)
mkdir -p "$T/x9"
case $(file -b -- "$LPKG") in
    *Zstandard*) zstd -dc -- "$LPKG" | tar -xf - -C "$T/x9" ;;
    *gzip*)      gzip -dc -- "$LPKG" | tar -xf - -C "$T/x9" ;;
    *)           tar -xf "$LPKG" -C "$T/x9" ;;
esac

B="$T/x9/wtool/lnk"
chk "相对软链的指向没被改写" "$(readlink "$B/themes/alias.zsh-theme")" "real.zsh-theme"
chk "嵌套的相对软链也没被改写" "$(readlink "$B/plugins/pp/alias.plugin.zsh")" "real.zsh"
chk "绝对软链保持绝对" "$(readlink "$B/abs-link")" "/etc/hostname"
if [ -r "$B/themes/alias.zsh-theme" ]; then
    ok "解压后软链打得开（不是断链）"
else
    bad "解压后是断链——--transform 又动了符号链接的指向"
fi
chk "顺着软链读到的内容对" "$(cat "$B/themes/alias.zsh-theme" 2>/dev/null)" "colours"

echo
printf 'publish_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
