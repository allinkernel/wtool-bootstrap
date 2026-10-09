#!/bin/sh
# publish_test.sh —— 测 pack-release / publish-release（命令大一统之后，ADR-023 / 026）
#
# 全程用打桩的 gh：不碰网络、不碰真 $WTOOL_STATE、不碰 $HOME、不碰真工作区。
# 验证点：
#   1. pack-release：source.zip 里第一层是项目路径（解压到工作区即与 repo sync 一致）、
#      包里不含 .git；相对软链在包里还是软链、指向没被改写
#   2. pack-release 写出的 docs/download.md 是文本且登记进 generated.tsv；
#      scripts/downloads.sh **不再生成**（那份清单归 scripts/release.json）
#   3. kind="none" 的项目不被发布；没有 wtool.xml 的仓（上游仓）根本不是 wtool 项目
#   4. 项目的 remote 名字是 github（repo 客户端）时也能找到目标仓
#   5. publish-release **只上传 __release/**，并且：
#        · __release/ 里没有 dist.json      → 拒绝，并指路 pack-release
#        · __release/.source 是 downloaded → 拒绝（别人打的包不许当自己的发）
#        · 上传的文件里没有 .source（内部标记不上传、不进清单）
#   6. 上传成功后写 scripts/release.json：project / repo / tag / base_url / commit /
#      packed_at / published_at / wtool_engine / dirty / targets[].target
#      （从 __output/*/ 目录名来）/ assets[].{name,role,bytes,sha256}（不含 .source）
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
# 解发布包：源码包/发布包现在是 zip（wtool_zip.py 打的；资产名是 ASCII 的
# source.zip / release.zip，包里的**条目名**仍可能是中文，所以 UTF-8 标志照样要设）
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

# 把小项目塞进 git（脏检查要求项目是干净仓库；__release/ 和 __output/ 是生成物，忽略）
git_init() {   # <项目目录>
    printf '__release/\noutput/\n' > "$1/.gitignore"
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
mkdir -p "$P1/__output/bin"
cat > "$P1/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="50">
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
# __output/ 是构建产物：进 release.zip，不进源码包（.gitignore 排除了它）
echo '#!/bin/sh' > "$P1/__output/bin/tmux-helper"
chmod +x "$P1/__output/bin/tmux-helper"
# 一个相对符号链接：验证包里不会把它改成断链
ln -sf tmux.conf "$P1/tmux.conf.alias"
git_init "$P1"
# repo 客户端建出来的 remote 叫 github（不是 origin）——名字不一样也要认得
git -C "$P1" remote add github ssh://git@github.com/allinkernel/wtool-tmux-config.git

_rc=0
wt "$T/bin" "$WS1" "$ST1" pack-release terminal/tmux --tag=v-1 > "$T/log1" 2>&1 || _rc=$?
chk "pack-release 退出码 0" "$_rc" "0"
[ "$_rc" = 0 ] || sed 's/^/     /' "$T/log1"
REL1="$P1/__release"
PKG="$REL1/source.zip"
if [ -f "$PKG" ]; then ok "产出了源码包 __release/source.zip"; else bad "没产出源码包"; fi
[ -f "$REL1/dist.json" ] && ok "写了 __release/dist.json" || bad "没有 __release/dist.json"
[ -f "$REL1/release.zip" ] && ok "写了 __release/release.zip" || bad "没有 __release/release.zip"

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

# release.zip 里是 __output/（构建产物）+ 声明面
chk "release.zip 里有构建产物 __output/bin/tmux-helper" \
    "$(J '
import sys, zipfile
print("yes" if "__output/bin/tmux-helper" in zipfile.ZipFile(sys.argv[1]).namelist() else "no")' \
       "$REL1/release.zip" 2>/dev/null || echo no)" "yes"

# 来源标记：publish-release 靠它拒绝"把刚下下来的包又传回去"
chk "__release/.source 第一列是 packed" "$(cut -f1 "$REL1/.source" 2>/dev/null)" "packed"
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
chk "dry-run 没有真的建/传 __release" \
    "$(grep -cE 'release (create|upload)' "$T/gh.log" || true)" "0"
if [ -f "$P1/scripts/release.json" ]; then
    bad "dry-run 不该写 scripts/release.json"
else
    ok "dry-run 没写 scripts/release.json"
fi
# --dry-run 要**把资产名打出来**，而且那一串名字必须全是 ASCII（BL-56 / H27：
# GitHub 把非 ASCII 名改写成 default.zip 且 gh 不报错，dry-run 是发布前唯一的核对时机）。
# 行首那截标签本身是中文（`wtool:   - [dry-run] 资产（N 个）: `），所以只取
# **最后一个冒号之后**那截 —— 那才是资产名。
_aline=$(grep '资产（' "$T/log2" || true)
_names=${_aline##*: }
[ -n "$_aline" ] && ok "--dry-run 列出了要传的资产名" \
    || { bad "--dry-run 没列资产名"; sed 's/^/     /' "$T/log2"; }
case $_names in
    *source.zip*) ok "--dry-run 的资产清单里有 source.zip" ;;
    *) bad "--dry-run 的资产清单里没有 source.zip" "$_names" ;;
esac
if LC_ALL=C printf '%s\n' "$_names" | grep -q '[^ -~]'; then
    bad "--dry-run 的资产清单里有非 ASCII 字符（GitHub 会改名成 default.zip）" "$_names"
else
    ok "--dry-run 的资产清单全是 ASCII"
fi

echo "== 3. publish-release：只上传 __release/ =="
# ★ .source 是内部标记，不能上传；同时把 --out 也验一下
: > "$T/gh.log"
_rc=0
wt "$T/bin" "$WS1" "$ST1" publish-release terminal/tmux --tag=v-1 --out="$T/out1" \
    > "$T/log3" 2>&1 || _rc=$?
chk "publish-release 退出码 0" "$_rc" "0"
[ "$_rc" = 0 ] || sed 's/^/     /' "$T/log3"
grep -q 'release create v-1 --repo allinkernel/wtool-tmux-config' "$T/gh.log" \
    && ok "对项目自己的仓建了 release（remote 叫 github 也认得）" \
    || { bad "没建 __release"; sed 's/^/     /' "$T/gh.log"; }
# ★ 缺陷 B：建 tag 时必须点名"被打包的那个 commit"（`--target=`）。
#   不传的话 gh 用仓库的**默认分支**建 tag —— tag 就指向远端 main 的 HEAD，
#   而资产是 ds_dev 那个 commit 打的包，`git checkout <tag>` 拿到的是另一棵树。
chk "★建 release 带 --target=<被打包的 commit>" \
    "$(grep -o -- '--target=[0-9a-f]*' "$T/gh.log" | head -1)" \
    "--target=$(git -C "$P1" rev-parse HEAD)"
grep -q 'release upload v-1 --repo allinkernel/wtool-tmux-config' "$T/gh.log" \
    && ok "上传到同一个仓" || bad "没上传"
grep -q 'source.zip' "$T/gh.log" && ok "上传了source.zip（pack-release 的产物）" \
    || bad "没上传source.zip"
grep -q 'release.zip' "$T/gh.log" && ok "上传了 release.zip" || bad "没上传 release.zip"
chk "★上传的文件里没有 .source（内部标记）" "$(grep -c '\.source' "$T/gh.log" || true)" "0"
[ -f "$T/out1/source.zip" ] && ok "--out 收到了产物" || bad "--out 没有产物"
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
    # ADR-025：形状由 <build kind> 决定，引擎不嗅探。这个项目**没有** <build>
    # （= kind="local"），__output/ 下是 __output/bin/ 这种**层名**而不是 <os>_<ver>/
    # —— 硬扫出来当 target 就是假信息，所以 targets 必须是空的。
    chk "没写 <build>（=local）→ targets 是空的，不把层名当 target" "$(J '
import json, sys
print(",".join(t["target"] for t in json.load(open(sys.argv[1]))["targets"]))' "$RJ")" ""
    chk "assets 的每个资产都有 name/role/bytes/sha256" "$(J '
import json, sys
need = ("name", "role", "bytes", "sha256")
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(",".join(sorted({k for a in d["assets"] for k in need if k not in a})))' "$RJ")" ""
    chk "★assets 里没有 .source" "$(J '
import json, sys
print(sum(1 for a in json.load(open(sys.argv[1]))["assets"] if a["name"] == ".source"))' "$RJ")" "0"
    # BL-56 / H27：清单里的资产名会**变成线上直链**，非 ASCII 名 GitHub 不接受
    chk "★assets 的名字全是 ASCII（非 ASCII 会被 GitHub 改写成 default.zip）" "$(J '
import json, sys
print(",".join(a["name"] for a in json.load(open(sys.argv[1]))["assets"]
               if any(ord(c) > 127 for c in a["name"])))' "$RJ")" ""
    chk "source.zip 的 role=source" "$(J '
import json, sys
print(next(a["role"] for a in json.load(open(sys.argv[1]))["assets"] if a["name"] == "source.zip"))' "$RJ")" "source"
    chk "release.zip 的 role=__release" "$(J '
import json, sys
print(next(a["role"] for a in json.load(open(sys.argv[1]))["assets"] if a["name"] == "release.zip"))' "$RJ")" "release"
    chk "source.zip 的 sha256 和盘上的一致" "$(J '
import json, sys
print(next(a["sha256"] for a in json.load(open(sys.argv[1]))["assets"] if a["name"] == "source.zip"))' "$RJ")" \
        "$(sha256sum -- "$PKG" | cut -d' ' -f1)"
    chk "source.zip 的 bytes 和盘上的一致" "$(J '
import json, sys
print(next(a["bytes"] for a in json.load(open(sys.argv[1]))["assets"] if a["name"] == "source.zip"))' "$RJ")" \
        "$(wc -c < "$PKG" | tr -d ' ')"
else
    bad "没有 scripts/release.json"
fi

echo "== 5b. 同一个 commit 重发：非交互拒绝、--force 才放行（BL-03）=="
#   release.json 里记着"这一版是哪个 commit 编的"。当前 HEAD 就是它 = 内容一个字
#   都不会变，重发十有八九是手滑 → 交互时问一句，**非交互时不猜**（脚本里跑的
#   命令绝不该卡在等输入上）。所以这里显式把 stdin 接到 /dev/null。
if [ -f "$RJ" ]; then
    chk "前置：release.json 记的 commit 就是 HEAD" \
        "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "$RJ")" \
        "$(git -C "$P1" rev-parse HEAD)"
    _packed_commit=$(J 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "$RJ")

    : > "$T/gh.log"
    _rc=0
    wt "$T/bin" "$WS1" "$ST1" publish-release terminal/tmux --tag=v-1 \
        < /dev/null > "$T/log5b" 2>&1 || _rc=$?
    [ "$_rc" != 0 ] && ok "同名 commit 重发：非交互直接拒绝（退出码非 0）" \
        || bad "同名 commit 重发居然放行了"
    case "$(cat "$T/log5b")" in
        *"已经发布过"*"--force"*) ok "说清了原因（commit 没变）和出路（--force）" ;;
        *) bad "没说清为什么拒绝、该怎么办"; sed 's/^/     /' "$T/log5b" ;;
    esac
    chk "拒绝时一个字节都没上传" \
        "$(grep -cE 'release (create|upload)' "$T/gh.log" || true)" "0"

    # 内容真的变了（新 commit）→ 不拦
    echo 'set -g status on' >> "$P1/tmux.conf"
    git -C "$P1" add -A
    git -C "$P1" -c user.name=t -c user.email=t@t commit -q -m change
    : > "$T/gh.log"
    _rc=0
    wt "$T/bin" "$WS1" "$ST1" publish-release terminal/tmux --tag=v-2 \
        < /dev/null > "$T/log5b2" 2>&1 || _rc=$?
    chk "新 commit 照常发布（不拦）" "$_rc" "0"
    grep -q 'release upload v-2' "$T/gh.log" && ok "新 commit 真的传了" \
        || { bad "新 commit 没传（不该拦的拦住了）"; sed 's/^/     /' "$T/log5b2"; }
    # ★ 缺陷 B（第二种情形，比上一条更关键）：**打包之后又提交了一个**，
    #   这时 --target 必须是 dist.json 里那个"打包时"的 commit，不能是当前 HEAD ——
    #   拿 HEAD 顶替等于把 tag 钉到一个和包无关的提交上（"改了代码没重新打包就发"
    #   是允许的，所以这两者真的会不一样）。
    chk "★打包后又提交：--target 仍是打包时那个 commit（不是当前 HEAD）" \
        "$(grep -o -- '--target=[0-9a-f]*' "$T/gh.log" | head -1)" \
        "--target=$_packed_commit"
    chk "而当前 HEAD 确实已经不是它了（这条才测得出东西）" \
        "$([ "$(git -C "$P1" rev-parse HEAD)" != "$_packed_commit" ] && echo yes || echo no)" "yes"
    # ⚠️ 声明里记的是**打包时那个 commit**（dist.json 的 commit），不是当前 HEAD：
    #    这次没重新 pack，发出去的就是老包 —— 声明必须如实说"这一版是哪个 commit 编的"。
    chk "发布声明仍记打包时那个 commit（没重打包就不假装是新版）" \
        "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "$RJ")" "$_packed_commit"
    chk "而当前 HEAD 确实已经不是它了（所以刚才没被拦）" \
        "$([ "$(git -C "$P1" rev-parse HEAD)" != "$_packed_commit" ] && echo yes || echo no)" "yes"

    # --force：明知同名也放行（"上次传到一半断了，原样重传"就是这种）
    : > "$T/gh.log"
    _rc=0
    wt "$T/bin" "$WS1" "$ST1" publish-release terminal/tmux --tag=v-2 --force \
        < /dev/null > "$T/log5b3" 2>&1 || _rc=$?
    chk "--force 放行同名 commit" "$_rc" "0"
    grep -q 'release upload v-2' "$T/gh.log" && ok "--force 之后真的重传了" \
        || bad "--force 了还是没传"
else
    bad "没有 scripts/release.json（5b 没法验）"
fi

echo "== 6. ★测试没有碰真工作区的文档 =="
# 这条断言是为了防住"测试改写真实文件"这类问题——它真的发生过一次。
# 宿主文件是 **download.md**（ADR-0042 把 wtool:downloads 块从 README 挪进了下载页；
# README 里现在只剩一行指过去的链接，不再带标记）。
_real_doc="$WS/wtool-base/download.md"
if [ -f "$_real_doc" ]; then
    if grep -q 'wtool:downloads' "$_real_doc" \
            && [ "$(grep -c '还没有发布过任何项目' "$_real_doc" || true)" = 0 ]; then
        ok "真工作区的 download.md 没被动过（下载块里是真链接）"
    else
        bad "真工作区的 download.md 被测试改动了"
    fi
else
    ok "真工作区没有 wtool-base（无所谓）"
fi
# 反向断言：README **不许**再带标记块 —— 带了就是两个真相源（ADR-0042 禁止）
if [ -f "$WS/wtool-base/README.md" ]; then
    grep -q '^<!-- >>> wtool:downloads >>> -->' "$WS/wtool-base/README.md" \
        && bad "真工作区 README 又带上了下载块标记（下载页只能有一个）" \
        || ok "真工作区 README 里没有下载块标记（只链接到 download.md）"
fi

echo "== 7. 拒绝：__release/ 里没有 dist.json（不许凭空发）=="
# publish-release 只认"本地打出来的包"：__release/ 里没有 dist.json 就不是包，
# 拒绝并指路 pack-release。⚠️ 这里不断言退出码 —— 今天拒绝也是退出 0
#（_failed 只统计不退出），断言 0 会把一个有争议的行为固定下来。
WS7="$T/ws7"; ST7="$T/state7"; P7="$WS7/nodist"
mkdir -p "$P7/__release"
cat > "$P7/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="10">
  <publish to="fakeowner/nodist"/>
</wtool>
EOF
git_init "$P7"
# 有人手工往 __release/ 里放了个文件 —— 它不是包
echo 'stray' > "$P7/__release/没清单.txt"
: > "$T/gh.log"
wt "$T/bin" "$WS7" "$ST7" publish-release nodist > "$T/log7" 2>&1 || true
grep -q '没有 dist.json' "$T/log7" && ok "报明了 __release/ 里没有 dist.json" \
    || { bad "没报 dist.json 缺失"; sed 's/^/     /' "$T/log7"; }
grep -q 'wtool pack-release nodist' "$T/log7" && ok "指路了 pack-release" \
    || { bad "没有指路 pack-release"; sed 's/^/     /' "$T/log7"; }
chk "拒绝之后什么都没传" "$(grep -cE 'release (create|upload)' "$T/gh.log" || true)" "0"

echo "== 8. 拒绝：__release/.source 是 downloaded（别人打的包不许当自己的发）=="
WS8="$T/ws8"; ST8="$T/state8"; P8="$WS8/dl"
mkdir -p "$P8/__release"
cat > "$P8/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="10">
  <publish to="fakeowner/dl"/>
</wtool>
EOF
git_init "$P8"
printf '{"project":"dl","repo":"someone/else","tag":"v-9","files":[],"volumes":[]}\n' \
    > "$P8/__release/dist.json"
printf 'downloaded\tsomeone/else\tv-9\tdeadbeef\t2026-01-01T00:00:00+08:00\n' \
    > "$P8/__release/.source"
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
<wtool schema="1" priority="10">
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
    || { bad "没有复用已存在的 __release"; sed 's/^/     /' "$T/log9"; }
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
# 同一份包再发一次：这就是 BL-03 要问一句的场景（同一 commit 重发），
# 这里是脚本、非交互，所以显式 --force —— 它本来就是"重试上一次没传完的"那个意思。
wt "$T/bin-flaky" "$WS9" "$ST9" publish-release racy --force > "$T/log9b" 2>&1 || _rc=$?
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
<wtool schema="1" priority="10">
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
<wtool schema="1" priority="10">
  <publish kind="none"/>
</wtool>
EOF
git_init "$WS11/aaa-none"
# 排在后面的正常项目：验"前一条不会把后一条吞掉"
cat > "$WS11/zzz-after/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="20">
  <publish to="fakeowner/zzz"/>
</wtool>
EOF
echo hi > "$WS11/zzz-after/README.md"
git_init "$WS11/zzz-after"
# 上游仓（neovim/neovim）自己没有 wtool.xml —— 它压根不是 wtool 项目，
# 伞项目用 <sub kind="none"> 替它表态。
cat > "$WS11/editor/astronvim_v5/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="90">
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
# 两个老名字的语义变了（download 以前一步到 __output/，现在只到 __release/），
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
<wtool schema="1" priority="10">
  <publish kind="script" script="publish.sh"/>
</wtool>
EOF
cat > "$WS13/k2/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="10">
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
<wtool schema="1" priority="10">
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
    "$([ -f "$WS13/legacy/__release/source.zip" ] && echo yes || echo no)" "yes"
_rc=0
wt "$T/bin" "$WS13" "$ST13" publish-release legacy --tag=l-1 > "$T/log13d" 2>&1 || _rc=$?
chk "publish-release legacy 退出码 0" "$_rc" "0"

echo "== 14. 脏检查：wtool 自己生成的不算脏，用户手改的仍算脏 =="
WS14="$T/ws14"; ST14="$T/state14"; P14="$WS14/dirty"
mkdir -p "$P14"
cat > "$P14/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="10">
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
<wtool schema="1" priority="10">
  <publish kind="source" to="fakeowner/lnk"/>
</wtool>
EOF
git_init "$P15"
chk "pack-release lnk" \
    "$(wt "$T/bin" "$WS15" "$ST15" pack-release lnk --repo=fakeowner/lnk --tag=lnk-1 > "$T/log15" 2>&1 && echo 0 || echo 1)" "0"
mkdir -p "$T/x15"
unzip_to "$P15/__release/source.zip" "$T/x15" || true

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

echo "== 16. ★下载表按「项目自己记着的 tag」刷新（缺陷 A：查错 tag → 表一直是旧的）=="
# 症状：wt_refresh_downloads 用 `wt_publish_tag`（模板 `snapshot-%Y-%m-%d`）求 tag，
# 无视 `publish-release --tag=ds_dev-2026-10-09` 的覆盖值 → 查的是一个不存在的 release
# → 查到 0 个资产 → 守卫拦住空表 → **文档一直停在旧版本，而且不报错**。
# 2026-10-09 实测：9 次发布全走了这条路，README 的 wtool:downloads 块还停在
# snapshot-2026-09-15。所以这里同时盯三件事：
#   ① 发布过的项目按 scripts/release.json 的 tag 查；② 没发布过的退回模板；
#   ③ 生成出来的命令要**能照着跑**（前缀防撞名 + 按扩展名解压）。
WS16="$T/ws16"; ST16="$T/state16"; P16="$WS16/alpha"; P16B="$WS16/beta"
mkdir -p "$P16" "$P16B" "$WS16/wtool-base"
cat > "$P16/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="10">
  <publish to="fakeowner/alpha"/>
</wtool>
EOF
echo 'demo' > "$P16/demo.txt"
git_init "$P16"
cat > "$P16B/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="20">
  <publish to="fakeowner/beta"/>
</wtool>
EOF
echo 'demo' > "$P16B/demo.txt"
git_init "$P16B"

# 打桩 gh：只有 `v-alpha`（alpha 发布声明里那个 tag）和模板 tag 有资产。
# 别的 tag 一律"查不到" —— 修复前 refresh 查的正是那个查不到的，于是表格不动。
# ⚠️ alpha 和 beta 的资产名**故意重名**（都叫 source.zip / dist.json，线上就是这样：
#    每个项目都发 source.zip）—— 生成器不加项目前缀就会互相覆盖，这条要测出来。
TODAY16=$(date +snapshot-%Y-%m-%d)
mkdir -p "$T/bin-dl"
cat > "$T/bin-dl/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$1 \$2" in
    "repo view")    echo "ADMIN"; exit 0 ;;
    "release view")
        case "\$3" in
            v-alpha)
                printf 'source.zip\thttps://github.com/fakeowner/alpha/releases/download/v-alpha/source.zip\t2048\n'
                printf 'dist.json\thttps://github.com/fakeowner/alpha/releases/download/v-alpha/dist.json\t100\n'
                exit 0 ;;
            $TODAY16)
                case "\$5" in
                    *beta*)
                        printf 'source.zip\thttps://github.com/fakeowner/beta/releases/download/$TODAY16/source.zip\t8192\n'
                        printf 'dist.json\thttps://github.com/fakeowner/beta/releases/download/$TODAY16/dist.json\t111\n'
                        printf 'pkg-2026-01-01.tar.gz\thttps://github.com/fakeowner/beta/releases/download/$TODAY16/pkg-2026-01-01.tar.gz\t4096\n'
                        exit 0 ;;
                esac
                exit 1 ;;
        esac
        exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/bin-dl/gh"

# 目标文档：块里**已经有一张表**（旧版本）—— 这样"空表也要拦住"那条守卫不会兜底，
# 能不能更新全看真的查到了资产。
DOC16="$WS16/wtool-base/README.md"
cat > "$DOC16" <<'EOF'
# 下载

<!-- >>> wtool:downloads >>> -->
| 项目 | 版本 | 包 | 大小 |
|---|---|---|---|
| alpha | [snapshot-2020-01-01](https://example.invalid/snapshot-2020-01-01) | [old.tar.gz](https://example.invalid/old.tar.gz) | 1.0K |
<!-- <<< wtool:downloads <<< -->
EOF

chk "pack-release alpha --tag=v-alpha" \
    "$(wt "$T/bin-dl" "$WS16" "$ST16" pack-release alpha --tag=v-alpha --repo=fakeowner/alpha \
        > "$T/log16a" 2>&1 && echo 0 || echo 1)" "0"
: > "$T/gh.log"
_rc=0
wt "$T/bin-dl" "$WS16" "$ST16" publish-release alpha --tag=v-alpha > "$T/log16b" 2>&1 || _rc=$?
chk "publish-release alpha --tag=v-alpha 退出码 0" "$_rc" "0"
[ "$_rc" = 0 ] || sed 's/^/     /' "$T/log16b"
chk "发布声明里记的是覆盖值 v-alpha" \
    "$(J 'import json,sys;print(json.load(open(sys.argv[1]))["tag"])' "$P16/scripts/release.json" 2>/dev/null || echo none)" "v-alpha"

# 发布成功后引擎自己会跑一遍刷新 —— 这里就是缺陷 A 的现场
chk "★刷新时查的是项目自己记着的 tag（v-alpha）" \
    "$(grep -c 'release view v-alpha --repo fakeowner/alpha --json assets' "$T/gh.log" || true)" "1"
chk "★没有再拿模板 tag 去查发布过的项目" \
    "$(grep -c "release view $TODAY16 --repo fakeowner/alpha" "$T/gh.log" || true)" "0"
grep -q 'v-alpha/source.zip' "$DOC16" \
    && ok "★下载块里已经是新 tag 的直链" \
    || { bad "下载块没更新（还是旧 tag）"; sed -n '/wtool:downloads/,/wtool:downloads <<</p' "$DOC16" | head -8 | sed 's/^/     /'; }
grep -q 'snapshot-2020-01-01' "$DOC16" \
    && bad "块里还留着旧版本那一行" || ok "旧版本那一行被换掉了"

# 没发布过的项目（没有 scripts/release.json）仍然按模板 tag 查 —— 老行为不能丢
: > "$T/gh.log"
_rc=0
wt "$T/bin-dl" "$WS16" "$ST16" refresh-downloads > "$T/log16c" 2>&1 || _rc=$?
chk "refresh-downloads（wtool docs refresh 同一个实现）退出码 0" "$_rc" "0"
chk "没发布过的项目退回模板 tag" \
    "$(grep -c "release view $TODAY16 --repo fakeowner/beta" "$T/gh.log" || true)" "1"
grep -q "download/$TODAY16/pkg-2026-01-01.tar.gz" "$DOC16" \
    && ok "模板 tag 那一行也进了表" || bad "没发布过的项目没进表"

# 生成出来的命令必须能照着跑：撞名 / 假命令都不行
# （alpha 和 beta 的资产名一样 —— 前缀没生效的话这里会数出重复）
chk "★每个资产的下载目标名互不相同（前缀防撞名）" \
    "$(awk '/^### bash/,/^### PowerShell/' "$DOC16" | grep -oE '^curl -fL -o [^ ]+' | awk '{print $4}' | sort | uniq -d | wc -l | tr -d ' ')" "0"
chk "下载行数 == 资产数（5 个：alpha 2 + beta 3）" \
    "$(grep -c '^curl -fL -o ' "$DOC16" || true)" "5"
chk "重名的资产各自带项目前缀" \
    "$(grep -c -E '^curl -fL -o (alpha|beta)-source\.zip ' "$DOC16" || true)" "2"
chk "★清单文件不被当包解（没有 tar -xf dist.json）" \
    "$(grep -c 'tar -xf.*dist\.json' "$DOC16" || true)" "0"
chk "★zip 用 unzip 解（tar -xf 解不开 zip）" \
    "$(grep -c '^unzip -o alpha-source.zip$' "$DOC16" || true)" "1"
chk "tar.gz 仍然用 tar -xf" \
    "$(awk '/^### bash/,/^### PowerShell/' "$DOC16" | grep -c '^tar -xf beta-pkg-2026-01-01.tar.gz$' || true)" "1"

# 幂等：再刷一遍内容不变，而且要明说"没有变化"
_before16=$(cat "$DOC16")
_rc=0
wt "$T/bin-dl" "$WS16" "$ST16" refresh-downloads > "$T/log16d" 2>&1 || _rc=$?
chk "再刷一遍退出码 0" "$_rc" "0"
chk "内容不变（幂等）" "$(cat "$DOC16")" "$_before16"
grep -q '没有变化' "$T/log16d" && ok "明说了「没有变化」" \
    || { bad "没有报「没有变化」"; sed 's/^/     /' "$T/log16d"; }

echo "== 17. ★拿不到「被打包的 commit」时不猜：警告 + 不传 --target =="
# 老包（不是这一版引擎打的）的 dist.json 里没有 commit。这时**不能**拿当前 HEAD 顶替
# （那正是缺陷 B 的成因），也不能传一个空的 --target= —— 只能警告 + 不传。
WS17="$T/ws17"; ST17="$T/state17"; P17="$WS17/nocommit"
mkdir -p "$P17/__release"
cat > "$P17/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="10">
  <publish to="fakeowner/nocommit"/>
</wtool>
EOF
git_init "$P17"
printf '{"project":"nocommit","repo":"fakeowner/nocommit","tag":"v-nc","files":[],"volumes":[]}\n' \
    > "$P17/__release/dist.json"
printf 'packed\tfakeowner/nocommit\tv-nc\t\t2026-01-01T00:00:00+08:00\n' \
    > "$P17/__release/.source"
: > "$T/gh.log"
_rc=0
wt "$T/bin" "$WS17" "$ST17" publish-release nocommit --tag=v-nc > "$T/log17" 2>&1 || _rc=$?
chk "publish-release 退出码 0（老包照样能发）" "$_rc" "0"
grep -q 'dist.json 里没有 commit' "$T/log17" && ok "警告说清了：dist.json 里没有 commit" \
    || { bad "没有警告"; sed 's/^/     /' "$T/log17"; }
grep -q 'release create v-nc --repo fakeowner/nocommit' "$T/gh.log" \
    && ok "release 照建（没有因为拿不到 sha 就停）" || bad "release 没建"
chk "★一个 --target 都没传（不猜、也不传空的）" \
    "$(grep -c -- '--target' "$T/gh.log" || true)" "0"

echo "== 18. ★下载页只能有一个：两个文档都带标记时拒绝刷新（ADR-0042）=="
# 症状（改前）：`grep -rl … | head -1` 挑遍历顺序靠前的那个，**不报错**。
# 于是"下载页有两份、只更新了一份"，另一份永远停在旧版本 —— 正是这个项目
# 一直在消灭的"同一个东西两个说法"。改成：多于一个就拒绝 + 列出全部候选 + 非零退出。
WS18="$T/ws18"; ST18="$T/state18"; P18="$WS18/alpha"
mkdir -p "$P18" "$WS18/wtool-base"
cat > "$P18/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="10">
  <publish to="fakeowner/alpha"/>
</wtool>
EOF
echo 'demo' > "$P18/demo.txt"
git_init "$P18"
# 让 alpha 有"自己记着的 tag"（`wt_publish_current_tag` 读的就是它）——
# 打桩 gh 只认 `v-alpha`，别的 tag 一律查不到。
mkdir -p "$P18/scripts"
printf '{\n  "schema": 1,\n  "project": "alpha",\n  "repo": "fakeowner/alpha",\n  "tag": "v-alpha"\n}\n' \
    > "$P18/scripts/release.json"
cat > "$WS18/wtool-base/README.md" <<'EOF'
# wtool

下载看 [download.md](download.md)。
EOF
cat > "$WS18/wtool-base/download.md" <<'EOF'
# 下载

<!-- >>> wtool:downloads >>> -->
<!-- <<< wtool:downloads <<< -->
EOF
# 第二份"下载页"：老 README 保留下来的标记块（就是这次搬迁要防的那种残留）
cat > "$WS18/wtool-base/OLD-downloads.md" <<'EOF'
# 旧下载页（残留）

<!-- >>> wtool:downloads >>> -->
| 项目 | 版本 | 包 | 大小 |
|---|---|---|---|
| alpha | [snapshot-2020-01-01](https://example.invalid/x) | [old.tar.gz](https://example.invalid/old.tar.gz) | 1.0K |
<!-- <<< wtool:downloads <<< -->
EOF
_before18a=$(cat "$WS18/wtool-base/download.md")
_before18b=$(cat "$WS18/wtool-base/OLD-downloads.md")
: > "$T/gh.log"
_rc=0
wt "$T/bin-dl" "$WS18" "$ST18" refresh-downloads > "$T/log18" 2>&1 || _rc=$?
chk "★两个标记文档 → 非零退出（不再静默挑一个）" "$_rc" "1"
grep -q '2 个文档带 wtool:downloads 标记' "$T/log18" \
    && ok "报出了标记文档的个数" || { bad "没说有几个"; sed 's/^/     /' "$T/log18"; }
grep -q 'wtool-base/OLD-downloads.md' "$T/log18" \
    && ok "把候选逐个列出来了（知道该删哪个）" || bad "没列出候选文档"
chk "★两个文件都一个字节没动（第一个）" "$(cat "$WS18/wtool-base/download.md")" "$_before18a"
chk "★两个文件都一个字节没动（第二个）" "$(cat "$WS18/wtool-base/OLD-downloads.md")" "$_before18b"
chk "★一个 gh 查询都没发（拒绝得早）" "$(grep -c 'release view' "$T/gh.log" || true)" "0"

# 删掉残留那个 → 恢复正常，刷进唯一的那个
rm -f "$WS18/wtool-base/OLD-downloads.md"
_rc=0
wt "$T/bin-dl" "$WS18" "$ST18" refresh-downloads > "$T/log18b" 2>&1 || _rc=$?
chk "只剩一个标记文档时退出码 0" "$_rc" "0"
grep -q 'v-alpha/source.zip' "$WS18/wtool-base/download.md" \
    && ok "★刷的是唯一的那个文档（download.md）" || bad "唯一那个没刷到"
chk "★刷完仍只有一个文档带标记" \
    "$(grep -rl --include='*.md' -E '^<!-- >>> wtool:downloads >>> -->[[:space:]]*$' "$WS18" 2>/dev/null | wc -l | tr -d ' ')" "1"

echo
printf 'publish_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
