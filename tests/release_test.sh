#!/bin/sh
# release_test.sh —— pack-release / unpack-release
#
# 全程在临时目录里跑，不碰真 $HOME、不碰真工作区、不连网。
# 验证点：
#   1. 源码.zip **真的读了 .gitignore**，而且永远排除 output/ release/
#      （不读的话 GB 级的 output/ 会被原样打进源码包 —— 实测过）
#   2. release.zip 带声明面（wtool.xml + env 文件），只下它也能 wtool install
#   3. dist.json：每卷的名字 / sha256 / 大小，按顺序逐个声明
#   4. 大包切分卷；分卷后原始大文件不留在 release/
#   5. scripts/downloads.sh（wt_dl_add 清单）和 docs/download.md 都是文本
#   6. pack-release → unpack-release 往返：output/ 逐字节回来，声明面回到项目根
#   7. 卷坏了 / 缺卷 → 拒绝解开（不许装上一个半成品）
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(dirname -- "$here")
WT="$boot/wtool.sh"
WT_ZIP="$boot/lib/wtool_zip.py"

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
# 注意最后要 return 0：不然"只带一个参数的 bad"会让函数返回非 0，
# 在 set -e 的脚本里直接终止整组测试（踩过）。
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"
         if [ $# -gt 1 ]; then printf '      %s\n' "$2"; fi; return 0; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$2]  实际 [$3]"; }
chk()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$3]  实际 [$2]"; }

py()  { python3 -W ignore "$@"; }
T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-rel.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM
export WTOOL_HOME="$T/home" WTOOL_STATE="$T/state"
mkdir -p "$WTOOL_HOME"

# 从 zip 里读成员名
zlist() { py -c 'import sys,zipfile
print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$1"; }
zhave() { zlist "$1" | grep -qx -- "$2"; }
zsha()  { sha256sum -- "$1" | cut -d' ' -f1; }

# --------------------------------------------------------------------------
printf '\n== 场景 1：pack-release 打包一个"要构建"的项目 ==\n'
WS="$T/ws1"
P="$WS/terminal/tmux"
mkdir -p "$P/scripts" "$P/output/ubuntu_24.04/bin" "$P/release" "$P/junk"
printf 'set -g mouse on\n'      > "$P/tmux.conf"
printf 'export DEMO=1\n'        > "$P/env.zsh"
printf 'export DEMO=1\n'        > "$P/env.bash"
printf 'junk 不该进包\n'        > "$P/junk/big.log"
printf 'debug 日志不该进包\n'   > "$P/debug.log"
printf '#!/bin/sh\ntrue\n'      > "$P/scripts/build.sh"
printf 'bin\n'                  > "$P/output/ubuntu_24.04/bin/tmux"
chmod +x "$P/output/ubuntu_24.04/bin/tmux"
cat > "$P/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="terminal/tmux" priority="50">
  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>
  <link home="~/.tmux.conf" wtool="~/.wtool/.tmux.conf" subproject="tmux.conf"/>
</wtool>
EOF
cat > "$P/.gitignore" <<'EOF'
# 产物目录本来就是 .gitignore 里的（这就是"必须读 .gitignore"的意义）
output/
release/
junk/
*.log
EOF
git -C "$P" init -q
git -C "$P" add -A
git -C "$P" -c user.name=t -c user.email=t@t commit -qm init

"$WT" pack-release "$P" --tag=v1.0 --repo=fakeowner/wtool-tmux > "$T/pack1.log" 2>&1 \
    || bad "pack-release 执行" "$(cat "$T/pack1.log")"

for f in 源码.zip release.zip dist.json 源码-hash.txt release-hash.txt; do
    [ -f "$P/release/$f" ] && ok "release/$f 产出了" || bad "release/$f 没产出"
done
[ -f "$P/scripts/downloads.sh" ] && ok "scripts/downloads.sh 产出了" || bad "scripts/downloads.sh 没产出"
[ -f "$P/docs/download.md" ] && ok "docs/download.md 产出了" || bad "docs/download.md 没产出"

# 1) 源码包：.gitignore 生效
SRC="$P/release/源码.zip"
zhave "$SRC" "wtool/terminal/tmux/tmux.conf" && ok "源码包第一层是 wtool/<项目路径>" \
    || bad "源码包路径不对" "$(zlist "$SRC" | head -5)"
zlist "$SRC" | grep -q '/output/' && bad "output/ 被打进源码包了" \
    || ok "output/ 没被打进源码包"
zlist "$SRC" | grep -q '\.log$' && bad "*.log 被打进源码包了" \
    || ok "*.log 没被打进源码包（.gitignore 生效）"
zlist "$SRC" | grep -q '/junk/' && bad "junk/ 被打进源码包了" \
    || ok "junk/ 没被打进源码包（.gitignore 生效）"
zlist "$SRC" | grep -q 'release/' && bad "release/ 被打进源码包了" \
    || ok "release/ 没被打进源码包"
zhave "$SRC" "wtool/.wtool-dist/terminal-tmux.json" \
    && ok "源码包带 .wtool-dist 标记（解压副本认得出自己）" \
    || bad "源码包没有 .wtool-dist 标记"

# 2) release 包：payload + 声明面
REL="$P/release/release.zip"
zhave "$REL" "output/ubuntu_24.04/bin/tmux" && ok "release.zip 里有产物" \
    || bad "release.zip 里没有产物"
for f in wtool.xml env.zsh env.bash; do
    zhave "$REL" "$f" && ok "release.zip 带声明面 $f" || bad "release.zip 缺声明面 $f"
done
mkdir -p "$T/x1"
py "$WT_ZIP" extract "$REL" "$T/x1"
[ -x "$T/x1/output/ubuntu_24.04/bin/tmux" ] && ok "解出来的可执行位还在" \
    || bad "可执行位丢了"

# 3) dist.json
D="$P/release/dist.json"
check "dist.json 里 project 对" "terminal/tmux" \
    "$(py -c 'import json,sys;print(json.load(open(sys.argv[1]))["project"])' "$D")"
check "dist.json 里 tag 对" "v1.0" \
    "$(py -c 'import json,sys;print(json.load(open(sys.argv[1]))["tag"])' "$D")"
check "dist.json 里 base_url 是拼出来的" \
    "https://github.com/fakeowner/wtool-tmux/releases/download/v1.0" \
    "$(py -c 'import json,sys;print(json.load(open(sys.argv[1]))["base_url"])' "$D")"
check "dist.json 声明了两个文件" "2" \
    "$(py -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["files"]))' "$D")"
check "dist.json 里 release.zip 的 sha256 对得上" "$(zsha "$REL")" \
    "$(py -c 'import json,sys
d=json.load(open(sys.argv[1]))
print([f["sha256"] for f in d["files"] if f["name"]=="release.zip"][0])' "$D")"
check "dist.json 里 release.zip 的 role 是 release" "release" \
    "$(py -c 'import json,sys
d=json.load(open(sys.argv[1]))
print([f["role"] for f in d["files"] if f["name"]=="release.zip"][0])' "$D")"

# 4) downloads.sh / download.md
grep -q "wt_dl_add 'release.zip'" "$P/scripts/downloads.sh" \
    && ok "downloads.sh 里有 wt_dl_add" || bad "downloads.sh 里没有 wt_dl_add" "$(cat "$P/scripts/downloads.sh")"
grep -q "WT_DL_TAG='v1.0'" "$P/scripts/downloads.sh" && ok "downloads.sh 记了 tag" \
    || bad "downloads.sh 没记 tag"
grep -q 'releases/download/v1.0/release.zip' "$P/docs/download.md" \
    && ok "download.md 里有直链" || bad "download.md 里没有直链"
grep -q 'wtool unpack-release terminal/tmux' "$P/docs/download.md" \
    && ok "download.md 里写了要敲哪条命令" || bad "download.md 没写命令"
grep -q "$(zsha "$REL")" "$P/scripts/downloads.sh" && ok "downloads.sh 里的 sha256 对" \
    || bad "downloads.sh 里的 sha256 不对"

# --------------------------------------------------------------------------
printf '\n== 场景 2：切分卷 + unpack-release 往返 ==\n'
"$WT" pack-release "$P" --tag=v1.0 --repo=fakeowner/wtool-tmux --volume-size=200 \
    > "$T/pack2.log" 2>&1 || bad "pack-release --volume-size 执行" "$(cat "$T/pack2.log")"

_nvol=$(py -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["volumes"]))' "$D")
[ "$_nvol" -ge 2 ] && ok "切出了分卷（$_nvol 卷）" || bad "没切分卷（$_nvol）"
check "分卷后原始大文件不留在 release/" "0" \
    "$(ls "$P/release"/release.zip 2>/dev/null | grep -c . || true)"
check "分卷名叫 <文件>-volNN（第一个是 vol01）" "release.zip-vol01" \
    "$(py -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(sorted(v["name"] for v in d["volumes"] if v["of"]=="release.zip")[0])' "$D")"
chk "每一卷都声明了拼给谁" \
    "$(py -c 'import json,sys
d=json.load(open(sys.argv[1]))
names={v["of"] for v in d["volumes"]}
print(",".join(sorted(names)))' "$D")" "release.zip,源码.zip"
check "分卷的 sha256 和磁盘一致" "$(zsha "$P/release/release.zip-vol01")" \
    "$(py -c 'import json,sys
d=json.load(open(sys.argv[1]))
print([v["sha256"] for v in d["volumes"] if v["name"]=="release.zip-vol01"][0])' "$D")"
grep -q "release.zip-vol01" "$P/scripts/downloads.sh" && ok "downloads.sh 列了分卷" \
    || bad "downloads.sh 没列分卷"
grep -q "^wt_dl_add 'release.zip'" "$P/scripts/downloads.sh" \
    && bad "downloads.sh 列了传不上去的原始大文件" \
    || ok "downloads.sh 不列被切开的原始大文件"

# 模拟"另一台只有浏览器的机器"：把 dist.json + 所有分卷放进一个新项目目录
P2="$T/ws2/terminal/tmux"
mkdir -p "$P2/release"
cp "$P/release/dist.json" "$P2/release/"
cp "$P/release"/*-vol* "$P2/release/"
"$WT" unpack-release "$P2" > "$T/unpack2.log" 2>&1 \
    || bad "unpack-release 执行" "$(cat "$T/unpack2.log")"
[ -x "$P2/output/ubuntu_24.04/bin/tmux" ] && ok "output/ 解出来了（可执行位也在）" \
    || bad "output/ 没解出来" "$(cat "$T/unpack2.log")"
check "payload 逐字节一致" "$(cat "$P/output/ubuntu_24.04/bin/tmux")" \
      "$(cat "$P2/output/ubuntu_24.04/bin/tmux")"
[ -f "$P2/wtool.xml" ] && ok "声明面解到了项目根" || bad "声明面没解到项目根"
[ -f "$P2/env.zsh" ] && ok "env.zsh 也解到了项目根" || bad "env.zsh 没解到项目根"

# 场景 2b：**改名（2026-09-28，release/ → output/）之前**打的包 —— 顶层是 release/<target>/
#   线上现成那一版就是这种（真包实测：release.zip-vol01 头两个条目是 env.bash / env.zsh，
#   第三个是 release/ubuntu_22.04/lang/bash/OWNED.tsv）。
#   unpack-release 这层不"改路径"（包里有啥解啥），但**必须提示一句** ——
#   不然下一步 `wtool install` 只会说"output/ 是空的"，人会去重下几百兆。
P2b="$T/ws2b/terminal/tmux"
mkdir -p "$P2b/release" "$T/oldpkg"
# 在**项目的一份拷贝**里打包：直接再 pack 一次 $P 会把场景 2 切好的分卷清掉
# （pack-release 会删掉它这次要重新生成的那些文件），场景 3 就没得用了。
P2b_SUB="$T/pj2b/terminal/tmux"
mkdir -p "$(dirname -- "$P2b_SUB")"
cp -a "$P" "$P2b_SUB"
rm -rf -- "$P2b_SUB/release"
"$WT" pack-release "$P2b_SUB" --tag=v1.0 --repo=fakeowner/wtool-tmux --volume-size=64M \
    > "$T/pack2b.log" 2>&1 || bad "pack-release（不切卷，拿来做旧布局包）" "$(cat "$T/pack2b.log")"
cp "$P2b_SUB/release/源码.zip" "$T/oldpkg/"
py - "$P2b_SUB/release/release.zip" "$T/oldpkg/release.zip" "$P2b_SUB/release/dist.json" "$T/oldpkg/dist.json" <<'PY'
import hashlib, json, os, shutil, sys, tempfile, zipfile
src, dst, dsrc, ddst = sys.argv[1:5]
tmp = tempfile.mkdtemp()
with zipfile.ZipFile(src) as z:
    z.extractall(tmp)
shutil.move(os.path.join(tmp, "output"), os.path.join(tmp, "release"))   # 改名前那一层
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for dp, dn, fn in os.walk(tmp):
        for f in sorted(fn):
            full = os.path.join(dp, f)
            z.write(full, os.path.relpath(full, tmp))
shutil.rmtree(tmp)
data = open(dst, "rb").read()
d = json.load(open(dsrc, encoding="utf-8"))
for e in d.get("files", []):
    if e["name"] == "release.zip":
        e["sha256"] = hashlib.sha256(data).hexdigest()
        e["bytes"] = len(data)
for v in d.get("volumes", []):
    if v.get("of") == "release.zip":
        v["sha256"] = hashlib.sha256(data).hexdigest()
        v["bytes"] = len(data)
json.dump(d, open(ddst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
cp "$T/oldpkg/dist.json" "$T/oldpkg/源码.zip" "$T/oldpkg/release.zip" "$P2b/release/"
"$WT" unpack-release "$P2b" > "$T/unpack2b.log" 2>&1 \
    || bad "unpack-release 跑旧布局的包" "$(cat "$T/unpack2b.log")"
grep -q '请 mv release output' "$T/unpack2b.log" \
    && ok "旧布局的包解开后提示 mv release output（不然下一步只会说 output/ 是空的）" \
    || bad "解旧布局的包没给迁移提示" "$(tail -3 "$T/unpack2b.log")"
[ -f "$P2b/release/ubuntu_24.04/bin/tmux" ] \
    && ok "旧包确实解成了 release/<target>/（提示的前提成立）" \
    || bad "旧包的布局没按原样解开"

# --------------------------------------------------------------------------
printf '\n== 场景 3：卷坏了 / 缺卷 → 拒绝解开 ==\n'
P3="$T/ws3/terminal/tmux"
mkdir -p "$P3/release"
cp "$P/release/dist.json" "$P3/release/"
cp "$P/release"/*-vol* "$P3/release/"
printf 'x' >> "$P3/release/release.zip-vol01"          # 弄坏第一卷
_rc=0
"$WT" unpack-release "$P3" > "$T/unpack3.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "卷 sha256 不对 → 拒绝解开（退出码非 0）" \
    || bad "卷坏了居然还解开成功"
grep -q '校验失败' "$T/unpack3.log" && ok "说清了是校验失败" \
    || bad "没说清失败原因" "$(cat "$T/unpack3.log")"
[ ! -e "$P3/output" ] && ok "拒绝之后没有留下半个 output/" || bad "留下了半个 output/"

P4="$T/ws4/terminal/tmux"
mkdir -p "$P4/release"
cp "$P/release/dist.json" "$P4/release/"               # 一卷都不放
_rc=0
"$WT" unpack-release "$P4" > "$T/unpack4.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "缺分卷 → 拒绝解开" || bad "缺分卷居然还解开成功"
grep -q '缺分卷' "$T/unpack4.log" && ok "说清了缺哪个卷" \
    || bad "没说清缺卷" "$(cat "$T/unpack4.log")"

# --------------------------------------------------------------------------
printf '\n== 场景 4：纯声明式项目（没有产物）只发源码包 ==\n'
P5="$T/ws5/shell/zsh"
mkdir -p "$P5"
printf 'alias ll="ls -alF"\n' > "$P5/env.zsh"
printf 'alias ll="ls -alF"\n' > "$P5/env.bash"
cat > "$P5/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="shell/zsh" priority="45">
  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>
</wtool>
EOF
git -C "$P5" init -q && git -C "$P5" add -A \
    && git -C "$P5" -c user.name=t -c user.email=t@t commit -qm init
"$WT" pack-release "$P5" --tag=v1 --repo=fakeowner/zsh > "$T/pack5.log" 2>&1 \
    || bad "纯声明式项目 pack-release 执行" "$(cat "$T/pack5.log")"
[ -f "$P5/release/源码.zip" ] && ok "源码包照常产出" || bad "源码包没产出"
[ -f "$P5/release/release.zip" ] && ok "release.zip 带声明面（只下它也能 install）" \
    || bad "release.zip 没产出"
zhave "$P5/release/release.zip" "wtool.xml" && ok "release.zip 里有 wtool.xml" \
    || bad "release.zip 里没有 wtool.xml"

# 只下 release.zip 的机器：解出来就能 wtool install
P6="$T/ws6/shell/zsh"
mkdir -p "$P6/release"
cp "$P5/release/dist.json" "$P6/release/"
cp "$P5/release/release.zip" "$P6/release/"
"$WT" unpack-release "$P6" > "$T/unpack6.log" 2>&1 \
    || bad "只下 release.zip 也能 unpack" "$(cat "$T/unpack6.log")"
[ -f "$P6/wtool.xml" ] && ok "只下 release.zip 也有声明面" || bad "声明面没解出来"

# --------------------------------------------------------------------------
printf '\n== 场景 5：dry-run 不产文件 ==\n'
P7="$T/ws7/p"
mkdir -p "$P7/scripts" "$P7/output"
printf 'x\n' > "$P7/output/x.bin"
printf 'true\n' > "$P7/scripts/build.sh"
cat > "$P7/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="p" priority="50"/>
EOF
git -C "$P7" init -q && git -C "$P7" add -A \
    && git -C "$P7" -c user.name=t -c user.email=t@t commit -qm init
"$WT" pack-release "$P7" --dry-run --tag=v1 --repo=o/r > "$T/pack7.log" 2>&1 \
    || bad "dry-run 执行" "$(cat "$T/pack7.log")"
[ ! -d "$P7/release" ] && ok "dry-run 不建 release/" || bad "dry-run 建了 release/"
grep -q 'dry-run' "$T/pack7.log" && ok "dry-run 输出了计划" || bad "dry-run 没输出计划"
[ ! -f "$P7/scripts/downloads.sh" ] && ok "dry-run 不写 downloads.sh" \
    || bad "dry-run 写了 downloads.sh"

# --------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'release_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
