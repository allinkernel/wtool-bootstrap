#!/bin/sh
# publish_test.sh —— 测 pack-release / publish-release（命令大一统之后，ADR-023 / 026）
#
# 全程用打桩的 gh：不碰网络、不碰真 $WTOOL_STATE、不碰 $HOME、不碰真工作区。
# 验证点：
#   1. pack-release：源码.zip 里第一层是项目路径（解压到工作区即与 repo sync 一致）、
#      包里不含 .git；相对软链在包里还是软链、指向没被改写
#   2. pack-release 写出的 docs/download.md 是文本且登记进 generated.tsv；
#      scripts/downloads.sh **不再生成**（那份清单归 scripts/release.json）
#   3. kind="none" 的项目不被发布；没有 wtool.xml 的仓（上游仓）根本不是 wtool 项目
#   4. 项目的 remote 名字是 github（repo 客户端）时也能找到目标仓
#   5. publish-release **只上传 release/**，并且：
#        · release/ 里没有 dist.json      → 拒绝，并指路 pack-release
#        · release/.source 是 downloaded → 拒绝（别人打的包不许当自己的发）
#        · 上传的文件里没有 .source（内部标记不上传、不进清单）
#   6. 上传成功后写 scripts/release.json：project / repo / tag / base_url / commit /
#      packed_at / published_at / wtool_engine / dirty / targets[].target
#      （从 output/*/ 目录名来）/ assets[].{name,role,bytes,sha256}（不含 .source）
#   7. 已经存在的 release 走复用（view 失败 / create 报 already exists / view 恢复）
#   8. 脏检查豁免 wtool 自己生成的文件（docs/download.md / scripts/release.json），
#      用户手改的仍算脏（要 --force）
#   9. wtool publish / wtool download 直接 die + 指路（不做兼容）
#  10. <publish kind="script"> / script= 是清单错误；scripts/publish.sh 不再被调用
#  11. 本地记录 publish.tsv
set -eu

# 环境里继承来的 WTOOL_* 会改变引擎行为（比如 WTOOL_FORCE / WTOOL_DRY_RUN），
# 先全部清掉；每次调用再显式指到临时目录。
for v in $(env | grep -o '^WTOOL_[A-Za-z_]*'); do unset "$v"; done

here=$(cd -- "$(dirname -- "$0")" && pwd)
WS=$(cd -- "$here/../.." && pwd)
WT="$WS/bootstrap/wtool.sh"
WT_ZIP="$WS/bootstrap/lib/wtool_zip.py"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3] 实际 [$2]）"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-pubtest.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/home"
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

# 安静一点：python 别刷 ResourceWarning
py() { python3 -W ignore "$@"; }
# 解发布包：源码包/发布包现在是 zip（wtool_zip.py 打的，中文名带 UTF-8 标志）
unzip_to() { python3 -W ignore "$WT_ZIP" extract "$1" "$2"; }

# 跑一段读文件的 python：J '<源码；sys.argv[1] 是文件路径，后面跟着其余参数>' <文件> [参数...]
J() { _j_src=$1; shift; py -c "$_j_src" "$@"; }

# 这个文件是文本吗（能按 UTF-8 解、没有 NUL 字节）
is_text() {
    J '
import sys
d = open(sys.argv[1], "rb").read()
try:
    d.decode("utf-8")
    print("no" if b"\0" in d else "yes")
except Exception:
    print("no")' "$1"
}

# 引擎调用入口：<gh 打桩目录> <临时工作区> <临时 state> <wtool 参数...>
# 三个环境变量一律显式给，绝不落到真的 $WTOOL_ROOT / $WTOOL_STATE / $HOME 上。
wt() {
    _w_bin=$1; _w_root=$2; _w_state=$3; shift 3
    PATH="$_w_bin:$PATH" WTOOL_ROOT="$_w_root" WTOOL_STATE="$_w_state" \
        WTOOL_HOME="$T/home" "$WT" "$@"
}

# 把小项目塞进 git（脏检查要求项目是干净仓库；release/ 和 output/ 是生成物，忽略）
git_init() {   # <项目目录>
    printf 'release/\noutput/\n' > "$1/.gitignore"
    git -C "$1" init -q
    git -C "$1" add -A
    git -C "$1" -c user.name=t -c user.email=t@t commit -q -m init
}

# 把 PWD 挪出工作区，避免相对路径干扰
cd "$T"

echo "== 1. pack-release：源码包结构 / 软链 / 生成物（terminal/tmux）=="
# ★ 用**临时工作区**，绝不能用真工作区：
#   pack-release 会扫 $WTOOL_ROOT 找带标记的文档并改写它，
#   跑真工作区的话一条测试就能把真的 README 洗掉（这个坑真踩过）。
WS1="$T/ws1"; ST1="$T/state1"; P1="$WS1/terminal/tmux"
mkdir -p "$P1/output/bin"
cat > "$P1/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="terminal/tmux" priority="50">
  <env src="env.zsh" shells="zsh"/>
  <link src="tmux.conf" dest=".tmux.conf"/>
</wtool>
EOF
echo 'set -g mouse on' > "$P1/tmux.conf"
echo 'export DEMO=1'  > "$P1/env.zsh"
cat > "$P1/install.sh" <<'EOF'
#!/bin/sh
echo "install ran" >&2
EOF
# output/ 是构建产物：进 release.zip，不进源码包（.gitignore 排除了它）
echo '#!/bin/sh' > "$P1/output/bin/tmux-helper"
chmod +x "$P1/output/bin/tmux-helper"
# 一个相对符号链接：验证包里不会把它改成断链
ln -sf tmux.conf "$P1/tmux.conf.alias"
git_init "$P1"
# repo 客户端建出来的 remote 叫 github（不是 origin）——名字不一样也要认得
git -C "$P1" remote add github ssh://git@github.com/allinkernel/wtool-tmux-config.git

_rc=0
wt "$T/bin" "$WS1" "$ST1" pack-release terminal/tmux --tag=v-1 > "$T/log1" 2>&1 || _rc=$?
chk "pack-release 退出码 0" "$_rc" "0"
[ "$_rc" = 0 ] || sed 's/^/     /' "$T/log1"
REL1="$P1/release"
PKG="$REL1/源码.zip"
if [ -f "$PKG" ]; then ok "产出了源码包 release/源码.zip"; else bad "没产出源码包"; fi
[ -f "$REL1/dist.json" ] && ok "写了 release/dist.json" || bad "没有 release/dist.json"
[ -f "$REL1/release.zip" ] && ok "写了 release/release.zip" || bad "没有 release/release.zip"

if [ -f "$PKG" ]; then
    LIST=$(J '
import sys, zipfile
print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$PKG")

    # 1) 第一层固定 wtool/
    if printf '%s\n' "$LIST" | grep -qv '^wtool/'; then
        bad "有成员不在 wtool/ 下"; printf '%s\n' "$LIST" | grep -v '^wtool/' | head -3 | sed 's/^/     /'
    else
        ok "所有成员都在 wtool/ 前缀下"
    fi

    # 2) 项目本身在正确位置
    if printf '%s\n' "$LIST" | grep -q '^wtool/terminal/tmux/tmux.conf$'; then
        ok "wtool/terminal/tmux/tmux.conf 在（解压后路径 == repo sync）"
    else
        bad "缺少 wtool/terminal/tmux/tmux.conf"
    fi

    # 3) 不含 .git（目录 / 文件）。注意别写成 '\.git' 就完事：
    #    那会把 .gitignore 也算进来，而 .gitignore 本来就该在包里。
    chk "不含 .git 成员" \
        "$(printf '%s\n' "$LIST" | grep -cE '(^|/)\.git(/|$)' || true)" "0"

    # 4) 带发布标记
    MARK=$(printf '%s\n' "$LIST" | grep '^wtool/\.wtool-dist/' || true)
    chk "带一个 .wtool-dist 标记" "$(printf '%s\n' "$MARK" | grep -c . || true)" "1"
    mkdir -p "$T/x1"
    unzip_to "$PKG" "$T/x1"
    MJ="$T/x1/wtool/.wtool-dist/terminal-tmux.json"
    if [ -f "$MJ" ]; then
        ok "标记文件能解出来"
        chk "标记里 view=release" "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["view"])' "$MJ")" "release"
        REAL=$(git -C "$P1" rev-parse HEAD)
        chk "标记里的 commit 是项目 HEAD" "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "$MJ")" "$REAL"
        chk "标记里 layout 指向 wtool/terminal/tmux" "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["layout"])' "$MJ")" "wtool/terminal/tmux"
    else
        bad "标记文件解不出来: $MJ"
    fi
    # 5) 相对软链在包里还是软链、指向没被改写
    chk "源码包里的相对软链还是软链、指向没被改写" \
        "$(readlink "$T/x1/wtool/terminal/tmux/tmux.conf.alias" 2>/dev/null || echo '(不是软链)')" "tmux.conf"
fi

# release.zip 里是 output/（构建产物）+ 声明面
chk "release.zip 里有构建产物 output/bin/tmux-helper" \
    "$(J '
import sys, zipfile
print("yes" if "output/bin/tmux-helper" in zipfile.ZipFile(sys.argv[1]).namelist() else "no")' \
       "$REL1/release.zip" 2>/dev/null || echo no)" "yes"

# 来源标记：publish-release 靠它拒绝"把刚下下来的包又传回去"
chk "release/.source 第一列是 packed" "$(cut -f1 "$REL1/.source" 2>/dev/null)" "packed"
chk ".source 记的目标仓对" "$(cut -f2 "$REL1/.source" 2>/dev/null)" "allinkernel/wtool-tmux-config"
chk ".source 记的 tag 对" "$(cut -f3 "$REL1/.source" 2>/dev/null)" "v-1"

# 生成物：downloads.sh 退休，download.md 还在，而且登记进 generated.tsv
if [ -f "$P1/scripts/downloads.sh" ]; then
    bad "scripts/downloads.sh 不该再生成（那份清单归 scripts/release.json）"
else
    ok "scripts/downloads.sh 不再生成（清单归 scripts/release.json）"
fi
DM="$P1/docs/download.md"
if [ -f "$DM" ]; then
    ok "写了 docs/download.md"
    chk "docs/download.md 是文本" "$(is_text "$DM")" "yes"
    chk "docs/download.md 登记进 generated.tsv" \
        "$(grep -c "^$DM" "$ST1/generated.tsv" 2>/dev/null || true)" "1"
else
    bad "没有 docs/download.md"
fi

echo "== 2. publish-release --dry-run：只说不做 =="
: > "$T/gh.log"
_rc=0
wt "$T/bin" "$WS1" "$ST1" publish-release terminal/tmux --tag=v-1 --dry-run \
    > "$T/log2" 2>&1 || _rc=$?
chk "dry-run 退出码 0" "$_rc" "0"
grep -q '\[dry-run\]' "$T/log2" && ok "打了 [dry-run] 标记" \
    || { bad "没有 dry-run 标记"; sed 's/^/     /' "$T/log2"; }
chk "dry-run 没有真的建/传 release" \
    "$(grep -cE 'release (create|upload)' "$T/gh.log" || true)" "0"
if [ -f "$P1/scripts/release.json" ]; then
    bad "dry-run 不该写 scripts/release.json"
else
    ok "dry-run 没写 scripts/release.json"
fi

echo "== 3. publish-release：只上传 release/ =="
# ★ .source 是内部标记，不能上传；同时把 --out 也验一下
: > "$T/gh.log"
_rc=0
wt "$T/bin" "$WS1" "$ST1" publish-release terminal/tmux --tag=v-1 --out="$T/out1" \
    > "$T/log3" 2>&1 || _rc=$?
chk "publish-release 退出码 0" "$_rc" "0"
[ "$_rc" = 0 ] || sed 's/^/     /' "$T/log3"
grep -q 'release create v-1 --repo allinkernel/wtool-tmux-config' "$T/gh.log" \
    && ok "对项目自己的仓建了 release（remote 叫 github 也认得）" \
    || { bad "没建 release"; sed 's/^/     /' "$T/gh.log"; }
grep -q 'release upload v-1 --repo allinkernel/wtool-tmux-config' "$T/gh.log" \
    && ok "上传到同一个仓" || bad "没上传"
grep -q '源码.zip' "$T/gh.log" && ok "上传了源码.zip（pack-release 的产物）" \
    || bad "没上传源码.zip"
grep -q 'release.zip' "$T/gh.log" && ok "上传了 release.zip" || bad "没上传 release.zip"
chk "★上传的文件里没有 .source（内部标记）" "$(grep -c '\.source' "$T/gh.log" || true)" "0"
[ -f "$T/out1/源码.zip" ] && ok "--out 收到了产物" || bad "--out 没有产物"
[ -f "$T/out1/.source" ] && bad "--out 不该带出 .source" || ok "--out 没带出 .source"

echo "== 4. 本地记录 =="
REC="$ST1/terminal/tmux/publish.tsv"
if [ -f "$REC" ]; then
    ok "写了 publish.tsv"
    chk "记录了目标仓" "$(awk -F'\t' '{print $2}' "$REC")" "allinkernel/wtool-tmux-config"
    chk "记录了 tag" "$(awk -F'\t' '{print $3}' "$REC")" "v-1"
else
    bad "没有 publish.tsv"
fi

echo "== 5. scripts/release.json：上传成功之后写的下载声明（ADR-026）=="
RJ="$P1/scripts/release.json"
if [ -f "$RJ" ]; then
    ok "写了 scripts/release.json"
    chk "必需字段一个不少" "$(J '
import json, sys
need = ["project", "repo", "tag", "base_url", "commit", "packed_at",
        "published_at", "wtool_engine", "dirty", "targets", "assets"]
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(",".join(k for k in need if k not in d))' "$RJ")" ""
    chk "project 对" "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["project"])' "$RJ")" "terminal/tmux"
    chk "repo 对" "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["repo"])' "$RJ")" "allinkernel/wtool-tmux-config"
    chk "tag 对" "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["tag"])' "$RJ")" "v-1"
    chk "base_url 是发布页地址" "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["base_url"])' "$RJ")" \
        "https://github.com/allinkernel/wtool-tmux-config/releases/download/v-1"
    chk "commit 是项目 HEAD" "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "$RJ")" \
        "$(git -C "$P1" rev-parse HEAD)"
    chk "packed_at 非空" "$([ -n "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["packed_at"])' "$RJ")" ] && echo yes || echo no)" "yes"
    chk "published_at 非空" "$([ -n "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["published_at"])' "$RJ")" ] && echo yes || echo no)" "yes"
    chk "wtool_engine 就是引擎版本" "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["wtool_engine"])' "$RJ")" \
        "$(wt "$T/bin" "$WS1" "$ST1" version | awk '{print $3}')"
    chk "dirty=false（只有 wtool 自己生成的文件是新的）" \
        "$(J 'import json,sys;print(str(json.load(open(sys.argv[1]))["dirty"]).lower())' "$RJ")" "false"
    chk "targets[].target 从 output/*/ 目录名来" "$(J '
import json, sys
print(",".join(t["target"] for t in json.load(open(sys.argv[1]))["targets"]))' "$RJ")" "bin"
    chk "assets 的每个资产都有 name/role/bytes/sha256" "$(J '
import json, sys
need = ("name", "role", "bytes", "sha256")
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(",".join(sorted({k for a in d["assets"] for k in need if k not in a})))' "$RJ")" ""
    chk "★assets 里没有 .source" "$(J '
import json, sys
print(sum(1 for a in json.load(open(sys.argv[1]))["assets"] if a["name"] == ".source"))' "$RJ")" "0"
    chk "源码.zip 的 role=source" "$(J '
import json, sys
print(next(a["role"] for a in json.load(open(sys.argv[1]))["assets"] if a["name"] == "源码.zip"))' "$RJ")" "source"
    chk "release.zip 的 role=release" "$(J '
import json, sys
print(next(a["role"] for a in json.load(open(sys.argv[1]))["assets"] if a["name"] == "release.zip"))' "$RJ")" "release"
    chk "源码.zip 的 sha256 和盘上的一致" "$(J '
import json, sys
print(next(a["sha256"] for a in json.load(open(sys.argv[1]))["assets"] if a["name"] == "源码.zip"))' "$RJ")" \
        "$(sha256sum -- "$PKG" | cut -d' ' -f1)"
    chk "源码.zip 的 bytes 和盘上的一致" "$(J '
import json, sys
print(next(a["bytes"] for a in json.load(open(sys.argv[1]))["assets"] if a["name"] == "源码.zip"))' "$RJ")" \
        "$(wc -c < "$PKG" | tr -d ' ')"
else
    bad "没有 scripts/release.json"
fi

echo "== 6. ★测试没有碰真工作区的文档 =="
# 这条断言是为了防住"测试改写真实文件"这类问题——它真的发生过一次。
_real_doc="$WS/wtool-base/README.md"
if [ -f "$_real_doc" ]; then
    if grep -q 'wtool:downloads' "$_real_doc" \
            && [ "$(grep -c '还没有发布过任何项目' "$_real_doc" || true)" = 0 ]; then
        ok "真工作区的 README 没被动过（下载块里是真链接）"
    else
        bad "真工作区的 README 被测试改动了"
    fi
else
    ok "真工作区没有 wtool-base（无所谓）"
fi

echo "== 7. 拒绝：release/ 里没有 dist.json（不许凭空发）=="
# publish-release 只认"本地打出来的包"：release/ 里没有 dist.json 就不是包，
# 拒绝并指路 pack-release。⚠️ 这里不断言退出码 —— 今天拒绝也是退出 0
#（_failed 只统计不退出），断言 0 会把一个有争议的行为固定下来。
WS7="$T/ws7"; ST7="$T/state7"; P7="$WS7/nodist"
mkdir -p "$P7/release"
cat > "$P7/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="nodist" priority="10">
  <publish to="fakeowner/nodist"/>
</wtool>
EOF
git_init "$P7"
# 有人手工往 release/ 里放了个文件 —— 它不是包
echo 'stray' > "$P7/release/没清单.txt"
: > "$T/gh.log"
wt "$T/bin" "$WS7" "$ST7" publish-release nodist > "$T/log7" 2>&1 || true
grep -q '没有 dist.json' "$T/log7" && ok "报明了 release/ 里没有 dist.json" \
    || { bad "没报 dist.json 缺失"; sed 's/^/     /' "$T/log7"; }
grep -q 'wtool pack-release nodist' "$T/log7" && ok "指路了 pack-release" \
    || { bad "没有指路 pack-release"; sed 's/^/     /' "$T/log7"; }
chk "拒绝之后什么都没传" "$(grep -cE 'release (create|upload)' "$T/gh.log" || true)" "0"

echo "== 8. 拒绝：release/.source 是 downloaded（别人打的包不许当自己的发）=="
WS8="$T/ws8"; ST8="$T/state8"; P8="$WS8/dl"
mkdir -p "$P8/release"
cat > "$P8/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="dl" priority="10">
  <publish to="fakeowner/dl"/>
</wtool>
EOF
git_init "$P8"
printf '{"project":"dl","repo":"someone/else","tag":"v-9","files":[],"volumes":[]}\n' \
    > "$P8/release/dist.json"
printf 'downloaded\tsomeone/else\tv-9\tdeadbeef\t2026-01-01T00:00:00+08:00\n' \
    > "$P8/release/.source"
: > "$T/gh.log"
wt "$T/bin" "$WS8" "$ST8" publish-release dl > "$T/log8" 2>&1 || true
grep -q '下载来的' "$T/log8" && ok "认出来这份包是下载来的" \
    || { bad "没认出 downloaded 来源"; sed 's/^/     /' "$T/log8"; }
grep -q 'wtool pack-release dl' "$T/log8" && ok "指路了 pack-release（要发就自己打一份）" \
    || { bad "没有指路 pack-release"; sed 's/^/     /' "$T/log8"; }
chk "拒绝之后什么都没传" "$(grep -cE 'release (create|upload)' "$T/gh.log" || true)" "0"

echo "== 9. release view 失败但 release 其实存在 → 复用，不硬失败 =="
# view 失败 ≠ 不存在：网络抖一下或 API 最终一致性都会让 view 报错，
# 这时 create 会撞 422 already exists。硬失败会让整个发布停在一个
# 早就建好的 release 上（实测在 shell/zsh 上撞过）。
WS9="$T/ws9"; ST9="$T/state9"; P9="$WS9/racy"
mkdir -p "$P9"
cat > "$P9/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="racy" priority="10">
  <publish to="fakeowner/racy"/>
</wtool>
EOF
git_init "$P9"
# 用引擎自己打包：tag 走默认模板，顺带验 pack / publish 两边的 tag 是同一个
chk "pack-release racy" "$(wt "$T/bin" "$WS9" "$ST9" pack-release racy --repo=fakeowner/racy > "$T/log9a" 2>&1 && echo 0 || echo 1)" "0"
TAG9=$(date +snapshot-%Y-%m-%d)

mkdir -p "$T/bin-race"
cat > "$T/bin-race/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$1 \$2" in
    "repo view")      echo "ADMIN"; exit 0 ;;
    "release view")   exit 1 ;;
    "release create") echo "HTTP 422: Release.tag_name already exists" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/bin-race/gh"
: > "$T/gh.log"
_rc=0
wt "$T/bin-race" "$WS9" "$ST9" publish-release racy > "$T/log9" 2>&1 || _rc=$?
chk "退出码是 0" "$_rc" "0"
grep -q '已经存在' "$T/log9" && ok "认 create 的 already exists，直接复用" \
    || { bad "没有复用已存在的 release"; sed 's/^/     /' "$T/log9"; }
grep -q '创建 release 失败' "$T/log9" && bad "误判成创建失败" || ok "没有误报创建失败"
grep -q '上传' "$T/log9" && ok "复用之后照常上传资产" || bad "复用后没上传"
grep -q "release upload $TAG9 --repo fakeowner/racy" "$T/gh.log" \
    && ok "上传用的是默认 tag 模板（pack / publish 一致）" \
    || { bad "没上传到 fakeowner/racy"; sed 's/^/     /' "$T/gh.log"; }

# 场景 9b：view 先抖了一下（说没有）、create 也失败了（但不是 already exists），
# 之后 view 恢复 —— 第二重判断该认出"其实已经存在"。
mkdir -p "$T/bin-flaky"
cat > "$T/bin-flaky/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$1 \$2" in
    "repo view")      echo "ADMIN"; exit 0 ;;
    "release view")
        [ -f "$T/flaky-seen" ] && exit 0
        : > "$T/flaky-seen"; exit 1 ;;
    "release create") echo "HTTP 504 Gateway Timeout" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/bin-flaky/gh"
rm -f "$T/flaky-seen"
: > "$T/gh.log"
_rc=0
wt "$T/bin-flaky" "$WS9" "$ST9" publish-release racy > "$T/log9b" 2>&1 || _rc=$?
chk "view 恢复之后认出已存在 → 复用（退出码 0）" "$_rc" "0"
grep -q 'view 现在能看到了' "$T/log9b" && ok "走的是 view 恢复那条判断" \
    || { bad "没有走 view 恢复那条路"; sed 's/^/     /' "$T/log9b"; }
grep -q "release upload $TAG9 --repo fakeowner/racy" "$T/gh.log" \
    && ok "复用之后照常上传资产" || bad "复用后没上传"

echo "== 10. 第三方仓必须被挡住（而不是静默中断整个发布）=="
# 曾经的真 bug：_perm=$(wt_publish_can_push ...) 在 set -e 下，
# 命令替换返回非 0 会让脚本静默退出——保护逻辑从没生效，整个发布却无声中断。
# 之前的测试打桩一律返回 ADMIN，正好绕过了这条路径。
WS10="$T/ws10"; ST10="$T/state10"; P10="$WS10/third"
mkdir -p "$P10"
cat > "$P10/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="third" priority="10">
  <publish to="neovim/neovim"/>
</wtool>
EOF
git_init "$P10"
chk "先给 third 打一份包（不然拒绝的理由就不是权限了）" \
    "$(wt "$T/bin" "$WS10" "$ST10" pack-release third --repo=neovim/neovim --tag=v-3 \
        > "$T/log10a" 2>&1 && echo 0 || echo 1)" "0"

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
wt "$T/bin-read" "$WS10" "$ST10" publish-release third --tag=v-3 > "$T/log10" 2>&1 || _rc=$?
chk "退出码是 0（不是被 set -e 静默打断）" "$_rc" "0"
grep -q '没有 neovim/neovim 的写权限' "$T/log10" \
    && ok "明确报了没有写权限" || { bad "没报权限问题"; sed 's/^/     /' "$T/log10"; }
grep -q 'kind="none"' "$T/log10" && ok "给了怎么改的建议" || bad "没给建议"
chk "没有产生任何 gh 写操作" "$(grep -cE 'release (create|upload)' "$T/gh.log" || true)" "0"

# --allow-foreign 是有意留的口子：明确说了"确实要试"才放行
: > "$T/gh.log"
_rc=0
wt "$T/bin-read" "$WS10" "$ST10" publish-release third --tag=v-3 --allow-foreign \
    > "$T/log10b" 2>&1 || _rc=$?
chk "--allow-foreign 放行（退出码 0）" "$_rc" "0"
grep -q 'release upload v-3 --repo neovim/neovim' "$T/gh.log" \
    && ok "--allow-foreign 之后真的传了" || { bad "--allow-foreign 没放行"; sed 's/^/     /' "$T/log10b"; }

echo "== 11. kind=none 不被发布 / 非 wtool 项目不认 / 循环不吞后面的项目 =="
WS11="$T/ws11"; ST11="$T/state11"
mkdir -p "$WS11/aaa-none" "$WS11/zzz-after" "$WS11/editor/astronvim_v5/nvim"
# 声明为不发布
cat > "$WS11/aaa-none/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="aaa-none" priority="10">
  <publish kind="none"/>
</wtool>
EOF
git_init "$WS11/aaa-none"
# 排在后面的正常项目：验"前一条不会把后一条吞掉"
cat > "$WS11/zzz-after/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="zzz-after" priority="20">
  <publish to="fakeowner/zzz"/>
</wtool>
EOF
echo hi > "$WS11/zzz-after/README.md"
git_init "$WS11/zzz-after"
# 上游仓（neovim/neovim）自己没有 wtool.xml —— 它压根不是 wtool 项目，
# 伞项目用 <sub kind="none"> 替它表态。
cat > "$WS11/editor/astronvim_v5/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="editor/astronvim_v5" priority="90">
  <publish kind="source">
    <sub path="nvim" kind="none"/>
  </publish>
</wtool>
EOF
git -C "$WS11/editor/astronvim_v5/nvim" init -q
git -C "$WS11/editor/astronvim_v5/nvim" remote add origin ssh://git@github.com/neovim/neovim.git
echo x > "$WS11/editor/astronvim_v5/nvim/x"
git -C "$WS11/editor/astronvim_v5/nvim" add -A
git -C "$WS11/editor/astronvim_v5/nvim" -c user.name=t -c user.email=t@t commit -q -m init

chk "先给 zzz-after 打一份包" \
    "$(wt "$T/bin" "$WS11" "$ST11" pack-release zzz-after --repo=fakeowner/zzz --tag=n-1 > "$T/log11a" 2>&1 && echo 0 || echo 1)" "0"
: > "$T/gh.log"
_rc=0
wt "$T/bin" "$WS11" "$ST11" publish-release --tag=n-1 > "$T/log11" 2>&1 || _rc=$?
chk "整体退出码 0" "$_rc" "0"
chk "kind=none 的项目被点到名" "$(grep -c '^wtool: ── aaa-none$' "$T/log11" || true)" "1"
chk "★它后面的项目没有被吞掉" "$(grep -c '^wtool: ── zzz-after$' "$T/log11" || true)" "1"
grep -q '声明为不发布，跳过' "$T/log11" && ok "kind=none 明确说了跳过" \
    || { bad "kind=none 没有被跳过"; sed 's/^/     /' "$T/log11"; }
grep -q 'zzz-after' "$T/gh.log" && ok "后面的项目确实发布了（gh 收到了它的仓）" \
    || bad "后面的项目没发布"
chk "对 neovim 没有任何写操作" \
    "$(grep -cE 'neovim/neovim.*release (create|upload)|release (create|upload).*neovim/neovim' "$T/gh.log" || true)" "0"

# 不是 wtool 项目的仓库，publish-release 根本不该认它
_rc=0
wt "$T/bin" "$WS11" "$ST11" publish-release nvim > "$T/log11b" 2>&1 || _rc=$?
chk "publish-release nvim 直接报找不到（退出码非 0）" \
    "$([ "$_rc" != 0 ] && echo yes || echo no)" "yes"
grep -q '找不到项目' "$T/log11b" && ok "说清了是找不到这个项目" \
    || { bad "错误信息不对"; sed 's/^/     /' "$T/log11b"; }

echo "== 12. 旧名字 publish / download 直接 die + 指路（不做兼容）=="
# 两个老名字的语义变了（download 以前一步到 output/，现在只到 release/），
# 静默兼容会做出错误的事 —— 所以是 die，不是"仍认但警告"。
_rc=0
wt "$T/bin" "$WS1" "$ST1" publish terminal/tmux > "$T/log12a" 2>&1 || _rc=$?
chk "wtool publish 退出码非 0" "$([ "$_rc" != 0 ] && echo yes || echo no)" "yes"
grep -q 'pack-release' "$T/log12a" && ok "publish 指路 pack-release" \
    || { bad "没指路 pack-release"; sed 's/^/     /' "$T/log12a"; }
grep -q 'publish-release' "$T/log12a" && ok "publish 指路 publish-release" || bad "没指路 publish-release"
_rc=0
wt "$T/bin" "$WS1" "$ST1" download terminal/tmux > "$T/log12b" 2>&1 || _rc=$?
chk "wtool download 退出码非 0" "$([ "$_rc" != 0 ] && echo yes || echo no)" "yes"
grep -q 'download-release' "$T/log12b" && ok "download 指路 download-release" \
    || { bad "没指路 download-release"; sed 's/^/     /' "$T/log12b"; }
grep -q 'unpack-release' "$T/log12b" && ok "download 指路 unpack-release" || bad "没指路 unpack-release"

echo "== 13. 脚本型发布退休：kind=script / script= 是清单错误 =="
WS13="$T/ws13"; ST13="$T/state13"
mkdir -p "$WS13/k1" "$WS13/k2" "$WS13/legacy/scripts"
cat > "$WS13/k1/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="k1" priority="10">
  <publish kind="script" script="publish.sh"/>
</wtool>
EOF
cat > "$WS13/k2/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="k2" priority="10">
  <publish kind="source" script="publish.sh"/>
</wtool>
EOF
_rc=0
wt "$T/bin" "$WS13" "$ST13" validate "$WS13/k1" > "$T/log13a" 2>&1 || _rc=$?
chk "kind=\"script\" 的清单 validate 失败" "$([ "$_rc" != 0 ] && echo yes || echo no)" "yes"
chk "报出 kind=script 只能是 source/none" "$(grep -c "kind='script'" "$T/log13a" || true)" "1"
_rc=0
wt "$T/bin" "$WS13" "$ST13" validate "$WS13/k2" > "$T/log13b" 2>&1 || _rc=$?
chk "script= 的清单 validate 失败" "$([ "$_rc" != 0 ] && echo yes || echo no)" "yes"
grep -q '已经取消' "$T/log13b" && ok "报出 script= 已经取消" \
    || { bad "没报 script= 错误"; sed 's/^/     /' "$T/log13b"; }

# 项目里就算留着 scripts/publish.sh，也没人再调它（文件存在不再等于能力声明）
cat > "$WS13/legacy/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="legacy" priority="10">
  <publish to="fakeowner/legacy"/>
</wtool>
EOF
cat > "$WS13/legacy/scripts/publish.sh" <<'EOF'
#!/bin/sh
# 脚本型发布已经退休：这个脚本不该再被任何人调用。
# 一旦被调用就会在 scripts/ 下留一个 ran.txt —— 测试就看它有没有出现。
: > "$(dirname -- "$0")/ran.txt"
EOF
git_init "$WS13/legacy"
chk "pack-release 走引擎那条路（不调项目脚本）" \
    "$(wt "$T/bin" "$WS13" "$ST13" pack-release legacy --repo=fakeowner/legacy --tag=l-1 \
        > "$T/log13c" 2>&1 && echo 0 || echo 1)" "0"
if [ -f "$WS13/legacy/scripts/ran.txt" ]; then
    bad "scripts/publish.sh 被调用了 —— 脚本型发布没有退休"
else
    ok "scripts/publish.sh 没被调用（文件存在不再等于能力声明）"
fi
chk "引擎照样打出了源码包" \
    "$([ -f "$WS13/legacy/release/源码.zip" ] && echo yes || echo no)" "yes"
_rc=0
wt "$T/bin" "$WS13" "$ST13" publish-release legacy --tag=l-1 > "$T/log13d" 2>&1 || _rc=$?
chk "publish-release legacy 退出码 0" "$_rc" "0"

echo "== 14. 脏检查：wtool 自己生成的不算脏，用户手改的仍算脏 =="
WS14="$T/ws14"; ST14="$T/state14"; P14="$WS14/dirty"
mkdir -p "$P14"
cat > "$P14/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="dirty" priority="10">
  <publish to="fakeowner/dirty"/>
</wtool>
EOF
echo 'v1' > "$P14/user.txt"
git_init "$P14"
chk "pack-release dirty" \
    "$(wt "$T/bin" "$WS14" "$ST14" pack-release dirty --repo=fakeowner/dirty --tag=d-1 > "$T/log14a" 2>&1 && echo 0 || echo 1)" "0"
# pack-release 刚写完 docs/download.md（未跟踪，但是 wtool 写的）—— 不该算脏
: > "$T/gh.log"
_rc=0
wt "$T/bin" "$WS14" "$ST14" publish-release dirty --tag=d-1 > "$T/log14" 2>&1 || _rc=$?
chk "pack-release 写的文档不算脏（发布成功）" "$_rc" "0"
grep -q '有未提交改动' "$T/log14" && bad "把 wtool 自己生成的 docs/download.md 当成脏了" \
    || ok "wtool 自己生成的文件被豁免"

# 用户手改一个**受版本控制**的文件 → 仍然算脏
echo 'v2' >> "$P14/user.txt"
: > "$T/gh.log"
_rc=0
wt "$T/bin" "$WS14" "$ST14" publish-release dirty --tag=d-1 > "$T/log14b" 2>&1 || _rc=$?
grep -q '有未提交改动' "$T/log14b" && ok "用户手改的文件仍算脏（拒绝发布）" \
    || { bad "没挡住用户手改的文件"; sed 's/^/     /' "$T/log14b"; }
chk "被挡住时没有上传" "$(grep -cE 'release (create|upload)' "$T/gh.log" || true)" "0"
_rc=0
wt "$T/bin" "$WS14" "$ST14" publish-release dirty --tag=d-1 --force > "$T/log14c" 2>&1 || _rc=$?
chk "--force 放行（退出码 0）" "$_rc" "0"
grep -q 'release upload d-1 --repo fakeowner/dirty' "$T/gh.log" \
    && ok "--force 之后真的传了" || { bad "--force 没放行"; sed 's/^/     /' "$T/log14c"; }

echo "== 15. ★相对符号链接不能在包里被改写（回归）=="
# 曾经的真 bug：--transform 默认连**符号链接的指向**一起改写，于是包里变成
#   themes/foo.zsh-theme -> wtool/bar.zsh-theme
# 解压出来全是断链。oh-my-zsh 里 themes/*.zsh-theme 和
# plugins/*/*.plugin.zsh 都中招了。
# 只在真去下载发布包解压时才暴露——光看 tar -tf 是看不出来的，
# 所以这条测试必须真解压再检查软链。
WS15="$T/ws15"; ST15="$T/state15"; P15="$WS15/lnk"
mkdir -p "$P15/themes" "$P15/plugins/pp"
printf 'colours\n' > "$P15/themes/real.zsh-theme"
ln -sf real.zsh-theme "$P15/themes/alias.zsh-theme"
printf 'plug\n' > "$P15/plugins/pp/real.zsh"
ln -sf real.zsh "$P15/plugins/pp/alias.plugin.zsh"
ln -sf /etc/hostname "$P15/abs-link"
cat > "$P15/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="lnk" priority="10">
  <publish kind="source" to="fakeowner/lnk"/>
</wtool>
EOF
git_init "$P15"
chk "pack-release lnk" \
    "$(wt "$T/bin" "$WS15" "$ST15" pack-release lnk --repo=fakeowner/lnk --tag=lnk-1 > "$T/log15" 2>&1 && echo 0 || echo 1)" "0"
mkdir -p "$T/x15"
unzip_to "$P15/release/源码.zip" "$T/x15" || true

B="$T/x15/wtool/lnk"
chk "相对软链的指向没被改写" "$(readlink "$B/themes/alias.zsh-theme")" "real.zsh-theme"
chk "嵌套的相对软链也没被改写" "$(readlink "$B/plugins/pp/alias.plugin.zsh")" "real.zsh"
chk "绝对软链保持绝对" "$(readlink "$B/abs-link")" "/etc/hostname"
if [ -r "$B/themes/alias.zsh-theme" ]; then
    ok "解压后软链打得开（不是断链）"
else
    bad "解压后是断链——打包又动了符号链接的指向"
fi
chk "顺着软链读到的内容对" "$(cat "$B/themes/alias.zsh-theme" 2>/dev/null)" "colours"

_rc=0
wt "$T/bin" "$WS15" "$ST15" publish-release lnk --tag=lnk-1 > "$T/log15b" 2>&1 || _rc=$?
chk "publish-release 退出码 0" "$_rc" "0"

echo
printf 'publish_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
