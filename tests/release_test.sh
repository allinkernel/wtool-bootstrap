#!/bin/sh
# release_test.sh —— pack-release / unpack-release
#
# 全程在临时目录里跑，不碰真 $HOME、不碰真工作区、不连网。
# 验证点：
#   1. 源码.zip **真的读了 .gitignore**，而且永远排除 __output/ __release/
#      （不读的话 GB 级的 __output/ 会被原样打进源码包 —— 实测过）
#   2. release.zip 带声明面（wtool.xml + env 文件），只下它也能 wtool install
#   3. dist.json：每卷的名字 / sha256 / 大小，按顺序逐个声明
#   4. 大包切分卷；分卷后原始大文件不留在 __release/
#   5. pack-release **不再写** scripts/downloads.sh（那份清单归 scripts/release.json，
#      见 harness/docs/adr/0026）；docs/download.md 仍然是文本、进 Git
#   6. pack-release → unpack-release 往返：__output/ 逐字节回来，声明面回到项目根
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
export WTOOL_ROOT="$T/ws1"   # 身份 = 相对工作区根的路径（ADR-0037）
P="$WS/terminal/tmux"
mkdir -p "$P/scripts" "$P/__output/ubuntu_24.04/bin" "$P/__release" "$P/junk"
printf 'set -g mouse on\n'      > "$P/tmux.conf"
printf 'export DEMO=1\n'        > "$P/env.zsh"
printf 'export DEMO=1\n'        > "$P/env.bash"
printf 'junk 不该进包\n'        > "$P/junk/big.log"
printf 'debug 日志不该进包\n'   > "$P/debug.log"
printf '#!/bin/sh\ntrue\n'      > "$P/scripts/build.sh"
printf 'bin\n'                  > "$P/__output/ubuntu_24.04/bin/tmux"
chmod +x "$P/__output/ubuntu_24.04/bin/tmux"
cat > "$P/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="50">
  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>
  <link home="~/.tmux.conf" wtool="~/.wtool/.tmux.conf" subproject="tmux.conf"/>
</wtool>
EOF
cat > "$P/.gitignore" <<'EOF'
# 产物目录本来就是 .gitignore 里的（这就是"必须读 .gitignore"的意义）
__output/
__release/
junk/
*.log
EOF
git -C "$P" init -q
git -C "$P" add -A
git -C "$P" -c user.name=t -c user.email=t@t commit -qm init

"$WT" pack-release "$P" --tag=v1.0 --repo=fakeowner/wtool-tmux > "$T/pack1.log" 2>&1 \
    || bad "pack-release 执行" "$(cat "$T/pack1.log")"

for f in 源码.zip release.zip dist.json 源码-hash.txt release-hash.txt; do
    [ -f "$P/__release/$f" ] && ok "__release/$f 产出了" || bad "__release/$f 没产出"
done
[ -f "$P/scripts/downloads.sh" ] && bad "scripts/downloads.sh 又出现了（ADR-026 已经删掉它）" \
    || ok "scripts/downloads.sh 不再生成（清单归 scripts/release.json）"
[ -f "$P/docs/download.md" ] && ok "docs/download.md 产出了" || bad "docs/download.md 没产出"
check "__release/.source 记了来源是本地打包" "packed" \
    "$(cut -f1 < "$P/__release/.source" 2>/dev/null || echo 无)"

# 1) 源码包：.gitignore 生效
SRC="$P/__release/源码.zip"
zhave "$SRC" "wtool/terminal/tmux/tmux.conf" && ok "源码包第一层是 wtool/<项目路径>" \
    || bad "源码包路径不对" "$(zlist "$SRC" | head -5)"
zlist "$SRC" | grep -q '/__output/' && bad "__output/ 被打进源码包了" \
    || ok "__output/ 没被打进源码包"
zlist "$SRC" | grep -q '\.log$' && bad "*.log 被打进源码包了" \
    || ok "*.log 没被打进源码包（.gitignore 生效）"
zlist "$SRC" | grep -q '/junk/' && bad "junk/ 被打进源码包了" \
    || ok "junk/ 没被打进源码包（.gitignore 生效）"
zlist "$SRC" | grep -q '__release/' && bad "__release/ 被打进源码包了" \
    || ok "__release/ 没被打进源码包"
zhave "$SRC" "wtool/.wtool-dist/terminal-tmux.json" \
    && ok "源码包带 .wtool-dist 标记（解压副本认得出自己）" \
    || bad "源码包没有 .wtool-dist 标记"

# 2) release 包：payload + 声明面
REL="$P/__release/release.zip"
zhave "$REL" "__output/ubuntu_24.04/bin/tmux" && ok "release.zip 里有产物" \
    || bad "release.zip 里没有产物"
for f in wtool.xml env.zsh env.bash; do
    zhave "$REL" "$f" && ok "release.zip 带声明面 $f" || bad "release.zip 缺声明面 $f"
done
mkdir -p "$T/x1"
py "$WT_ZIP" extract "$REL" "$T/x1"
[ -x "$T/x1/__output/ubuntu_24.04/bin/tmux" ] && ok "解出来的可执行位还在" \
    || bad "可执行位丢了"

# 3) dist.json
D="$P/__release/dist.json"
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

# 4) download.md（给人看的）
grep -q 'releases/download/v1.0/release.zip' "$P/docs/download.md" \
    && ok "download.md 里有直链" || bad "download.md 里没有直链"
grep -q 'wtool unpack-release terminal/tmux' "$P/docs/download.md" \
    && ok "download.md 里写了要敲哪条命令" || bad "download.md 没写命令"

# --------------------------------------------------------------------------
printf '\n== 场景 2：切分卷 + unpack-release 往返 ==\n'
"$WT" pack-release "$P" --tag=v1.0 --repo=fakeowner/wtool-tmux --volume-size=200 \
    > "$T/pack2.log" 2>&1 || bad "pack-release --volume-size 执行" "$(cat "$T/pack2.log")"

_nvol=$(py -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["volumes"]))' "$D")
[ "$_nvol" -ge 2 ] && ok "切出了分卷（$_nvol 卷）" || bad "没切分卷（$_nvol）"
check "分卷后原始大文件不留在 __release/" "0" \
    "$(ls "$P/__release"/release.zip 2>/dev/null | grep -c . || true)"
check "分卷名叫 <文件>-volNN（第一个是 vol01）" "release.zip-vol01" \
    "$(py -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(sorted(v["name"] for v in d["volumes"] if v["of"]=="release.zip")[0])' "$D")"
chk "每一卷都声明了拼给谁" \
    "$(py -c 'import json,sys
d=json.load(open(sys.argv[1]))
names={v["of"] for v in d["volumes"]}
print(",".join(sorted(names)))' "$D")" "release.zip,源码.zip"
check "分卷的 sha256 和磁盘一致" "$(zsha "$P/__release/release.zip-vol01")" \
    "$(py -c 'import json,sys
d=json.load(open(sys.argv[1]))
print([v["sha256"] for v in d["volumes"] if v["name"]=="release.zip-vol01"][0])' "$D")"
# 分卷信息现在只在 dist.json 里（downloads.sh 已删）
py -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print(",".join(sorted(v["name"] for v in d["volumes"] if v["of"]=="release.zip"))[:40])' "$D" \
    | grep -q "release.zip-vol01" && ok "dist.json 列了分卷" || bad "dist.json 没列分卷"

# 模拟"另一台只有浏览器的机器"：把 dist.json + 所有分卷放进一个新项目目录
P2="$T/ws2/terminal/tmux"
export WTOOL_ROOT="$T/ws2"
mkdir -p "$P2/__release"
cp "$P/__release/dist.json" "$P2/__release/"
cp "$P/__release"/*-vol* "$P2/__release/"
"$WT" unpack-release "$P2" > "$T/unpack2.log" 2>&1 \
    || bad "unpack-release 执行" "$(cat "$T/unpack2.log")"
[ -x "$P2/__output/ubuntu_24.04/bin/tmux" ] && ok "__output/ 解出来了（可执行位也在）" \
    || bad "__output/ 没解出来" "$(cat "$T/unpack2.log")"
check "payload 逐字节一致" "$(cat "$P/__output/ubuntu_24.04/bin/tmux")" \
      "$(cat "$P2/__output/ubuntu_24.04/bin/tmux")"
[ -f "$P2/wtool.xml" ] && ok "声明面解到了项目根" || bad "声明面没解到项目根"
[ -f "$P2/env.zsh" ] && ok "env.zsh 也解到了项目根" || bad "env.zsh 没解到项目根"

printf '\n== 场景 2c：unpack-release 的 --dry-run（不许真解包）与 --from=（不许被忽略）==\n'
#   ① 原来 `--dry-run` 只被 cmd_unpack_release 解析掉，写入在 wt_unpack_release 里：
#      拼卷（`: > $out` + `cat >>`）和 wt_unpack_one 都**没有 dry 守卫** →
#      dry-run 会真的把产物铺进 __output/（和真跑逐字相同，文档却说它"只出计划"）。
#   ② 原来 `--from=<目录>` 被当第 3 个参数传进去，而函数只读 $1/$2 → 静默丢掉：
#      "指定了下载目录，却去 <项目>/__release/ 找 dist.json"。
P2c="$T/ws2c/terminal/tmux"
export WTOOL_ROOT="$T/ws2c"
mkdir -p "$P2c/__release" "$T/fromdir"
cp "$P/__release/dist.json" "$P2c/__release/"
cp "$P/__release"/*-vol* "$P2c/__release/"
cp "$P/__release/dist.json" "$T/fromdir/"
cp "$P/__release"/*-vol* "$T/fromdir/"
_rc=0
"$WT" unpack-release "$P2c" --dry-run > "$T/unpack2c.log" 2>&1 || _rc=$?
[ "$_rc" = 0 ] && ok "dry-run 退出码 0" || bad "dry-run 失败" "$(cat "$T/unpack2c.log")"
chk "★--dry-run 之后 __output/ 里零文件（一个字节都不许写）" "0" \
    "$(find "$P2c" -path '*/__output/*' -type f 2>/dev/null | wc -l | tr -d ' ')"
[ -e "$P2c/__output" ] && bad "dry-run 建了 __output/" || ok "dry-run 连 __output/ 都不建"
grep -q '什么都没解开' "$T/unpack2c.log" && ok "dry-run 的收尾语说清了没解开" \
    || bad "dry-run 收尾语在撒谎" "$(tail -3 "$T/unpack2c.log")"
# --from=：新项目目录里**没有** __release/，dist.json 与分卷只在 $T/fromdir/ 里
P2d="$T/ws2d/terminal/tmux"
mkdir -p "$P2d"
_rc=0
"$WT" unpack-release "$P2d" > "$T/unpack2d.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "没有 __release/ 也没给 --from → 拒绝（不猜）" || bad "居然成功了"
grep -q 'dist.json' "$T/unpack2d.log" && grep -q -- '--from=' "$T/unpack2d.log" \
    && ok "报错说清缺什么、指了 --from=" || bad "报错没说清" "$(cat "$T/unpack2d.log")"
_rc=0
"$WT" unpack-release "$P2d" --from="$T/fromdir" > "$T/unpack2d2.log" 2>&1 || _rc=$?
[ "$_rc" = 0 ] && ok "★--from=<目录> 真的被用上了（不再被静默忽略）" \
    || bad "--from 没生效（参数被丢掉）" "$(cat "$T/unpack2d2.log")"
[ -x "$P2d/__output/ubuntu_24.04/bin/tmux" ] && ok "--from 那个目录里的包解出来了" \
    || bad "没解出来" "$(tail -5 "$T/unpack2d2.log")"


# 场景 2b：**改名（2026-09-28，__release/ → __output/）之前**打的包 —— 顶层是 __release/<target>/
#   线上现成那一版就是这种（真包实测：release.zip-vol01 头两个条目是 env.bash / env.zsh，
#   第三个是 __release/ubuntu_22.04/lang/bash/OWNED.tsv）。
#   unpack-release 这层不"改路径"（包里有啥解啥），但**必须提示一句** ——
#   不然下一步 `wtool install` 只会说"__output/ 是空的"，人会去重下几百兆。
P2b="$T/ws2b/terminal/tmux"
export WTOOL_ROOT="$T/ws2b"
mkdir -p "$P2b/__release" "$T/oldpkg"
# 在**项目的一份拷贝**里打包：直接再 pack 一次 $P 会把场景 2 切好的分卷清掉
# （pack-release 会删掉它这次要重新生成的那些文件），场景 3 就没得用了。
P2b_SUB="$T/pj2b/terminal/tmux"
export WTOOL_ROOT="$T/pj2b"
mkdir -p "$(dirname -- "$P2b_SUB")"
cp -a "$P" "$P2b_SUB"
rm -rf -- "$P2b_SUB/__release"
"$WT" pack-release "$P2b_SUB" --tag=v1.0 --repo=fakeowner/wtool-tmux --volume-size=64M \
    > "$T/pack2b.log" 2>&1 || bad "pack-release（不切卷，拿来做旧布局包）" "$(cat "$T/pack2b.log")"
cp "$P2b_SUB/__release/源码.zip" "$T/oldpkg/"
py - "$P2b_SUB/__release/release.zip" "$T/oldpkg/release.zip" "$P2b_SUB/__release/dist.json" "$T/oldpkg/dist.json" <<'PY'
import hashlib, json, os, shutil, sys, tempfile, zipfile
src, dst, dsrc, ddst = sys.argv[1:5]
tmp = tempfile.mkdtemp()
with zipfile.ZipFile(src) as z:
    z.extractall(tmp)
shutil.move(os.path.join(tmp, "__output"), os.path.join(tmp, "release"))   # 模拟改名前的旧包：output/ 那时候叫 release/
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
cp "$T/oldpkg/dist.json" "$T/oldpkg/源码.zip" "$T/oldpkg/release.zip" "$P2b/__release/"
"$WT" unpack-release "$P2b" > "$T/unpack2b.log" 2>&1 \
    || bad "unpack-release 跑旧布局的包" "$(cat "$T/unpack2b.log")"
grep -q 'mv release __output' "$T/unpack2b.log" \
    && ok "旧布局的包解开后提示 mv release __output（不然下一步只会说 __output/ 是空的）" \
    || bad "解旧布局的包没给迁移提示" "$(tail -3 "$T/unpack2b.log")"
[ -f "$P2b/release/ubuntu_24.04/bin/tmux" ] \
    && ok "旧包确实解成了 release/<target>/（提示的前提成立）" \
    || bad "旧包的布局没按原样解开"

# --------------------------------------------------------------------------
printf '\n== 2c：源码包必须排除**新旧六个**产物目录（ADR-0033）==\n'
#   为什么单独守这条：老工作区的磁盘上还躺着 output/ release/ layer/（GB 级），
#   而"没有 git 时"走的是引擎自己的 walk —— 那张忽略表少一个名字，
#   就能把一个 1GB 的产物目录打进源码包。
P2c="$T/ws2c/packdemo"; mkdir -p "$P2c"
export WTOOL_ROOT="$T/ws2c"
cd "$P2c" || exit 1
git init -q .; git -C "$P2c" remote add origin https://github.com/fake/packdemo.git
printf 'keep\n' > keep.txt
for d in __output __release __layer output release layer; do
    mkdir -p "$P2c/$d"; printf 'BIG\n' > "$P2c/$d/junk.bin"
done
printf '/__output/\n/__release/\n/__layer/\n' > "$P2c/.gitignore"
mkdir -p "$P2c/scripts"
printf '#!/bin/sh\ntrue\n' > "$P2c/scripts/build.sh"
cat > "$P2c/wtool.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="50">
</wtool>
XML
git -C "$P2c" add -A; git -C "$P2c" -c user.name=t -c user.email=t@t commit -qm init
"$WT" pack-release "$P2c" --tag=v1 > "$T/pack2c.log" 2>&1 \
    || bad "pack-release 跑不动" "$(cat "$T/pack2c.log")"
_SRC=$(ls "$P2c"/__release/源码.zip "$P2c"/__release/*source*.zip 2>/dev/null | head -1)
if [ -n "$_SRC" ]; then
    _bad=$(python3 - "$_SRC" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    print(" ".join(n for n in z.namelist()
                   if any(("/%s/" % d) in n for d in
                          ("__output", "__release", "__layer", "output", "release", "layer"))))
PY
)
    [ -z "$_bad" ] && ok "六个产物目录（新三名 + 旧三名）都没进源码包" \
        || bad "源码包里混进了产物目录: $_bad"
else
    bad "没找到源码包（场景 2c 的 fixture 有问题）"
fi
cd "$here" || exit 1

# --------------------------------------------------------------------------
printf '\n== 场景 3：卷坏了 / 缺卷 → 拒绝解开 ==\n'
P3="$T/ws3/terminal/tmux"
export WTOOL_ROOT="$T/ws3"
mkdir -p "$P3/__release"
cp "$P/__release/dist.json" "$P3/__release/"
cp "$P/__release"/*-vol* "$P3/__release/"
printf 'x' >> "$P3/__release/release.zip-vol01"          # 弄坏第一卷
_rc=0
"$WT" unpack-release "$P3" > "$T/unpack3.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "卷 sha256 不对 → 拒绝解开（退出码非 0）" \
    || bad "卷坏了居然还解开成功"
grep -q '校验失败' "$T/unpack3.log" && ok "说清了是校验失败" \
    || bad "没说清失败原因" "$(cat "$T/unpack3.log")"
[ ! -e "$P3/__output" ] && ok "拒绝之后没有留下半个 __output/" || bad "留下了半个 __output/"

P4="$T/ws4/terminal/tmux"
export WTOOL_ROOT="$T/ws4"
mkdir -p "$P4/__release"
cp "$P/__release/dist.json" "$P4/__release/"               # 一卷都不放
_rc=0
"$WT" unpack-release "$P4" > "$T/unpack4.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "缺分卷 → 拒绝解开" || bad "缺分卷居然还解开成功"
grep -q '缺分卷' "$T/unpack4.log" && ok "说清了缺哪个卷" \
    || bad "没说清缺卷" "$(cat "$T/unpack4.log")"

# --------------------------------------------------------------------------
printf '\n== 场景 4：没有构建能力的项目（纯声明式）只发源码包 ==\n'
#   ADR-0039：`__output/` 是空的、也没有构建能力（没有 scripts/build.sh、
#   没有 build/layers.tsv）→ release.zip 里**只剩声明面**，而那三个文件
#   （wtool.xml / env.zsh / env.bash）源码包里本来就有。实测 tmux：
#   源码包 15 个文件 20060 字节 vs release 包 3 个文件 2210 字节 —— 子集。
P5="$T/ws5/shell/zsh"
export WTOOL_ROOT="$T/ws5"
mkdir -p "$P5"
printf 'alias ll="ls -alF"\n' > "$P5/env.zsh"
printf 'alias ll="ls -alF"\n' > "$P5/env.bash"
cat > "$P5/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="45">
  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>
</wtool>
EOF
git -C "$P5" init -q && git -C "$P5" add -A \
    && git -C "$P5" -c user.name=t -c user.email=t@t commit -qm init
"$WT" pack-release "$P5" --tag=v1 --repo=fakeowner/zsh > "$T/pack5.log" 2>&1 \
    || bad "纯声明式项目 pack-release 执行" "$(cat "$T/pack5.log")"
[ -f "$P5/__release/源码.zip" ] && ok "源码包照常产出" || bad "源码包没产出"
[ -f "$P5/__release/源码-hash.txt" ] && ok "源码包的 sha256 也写了" || bad "源码-hash.txt 没产出"
[ -f "$P5/__release/release.zip" ] \
    && bad "还是打了 release.zip（没有构建能力时不该打，ADR-0039）" \
    || ok "没有 release.zip（没有构建能力的项目只发源码包）"
[ -f "$P5/__release/release-hash.txt" ] \
    && bad "还是写了 release-hash.txt（它指向一个不存在的文件，会被当资产传上去）" \
    || ok "没有 release-hash.txt（不留指向不存在文件的 hash）"
grep -q '只发源码包' "$T/pack5.log" && ok "pack-release 说清了为什么只发源码包" \
    || bad "pack-release 没说清" "$(cat "$T/pack5.log")"
check "dist.json 只声明一个文件" "1" \
    "$(py -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["files"]))' \
        "$P5/__release/dist.json")"
check "声明的那一个是源码包（role=source）" "source" \
    "$(py -c 'import json,sys
print(json.load(open(sys.argv[1]))["files"][0]["role"])' "$P5/__release/dist.json")"
# 下载页要跟着变：不能还写着"install 只认 release.zip"，那一版根本没有它
grep -q '只有源码包' "$P5/docs/download.md" \
    && ok "下载页说清了这一版只有源码包" || bad "下载页没说清" "$(cat "$P5/docs/download.md")"
grep -q 'release\.zip' "$P5/docs/download.md" \
    && bad "下载页还在提 release.zip（那一版没有这个文件）" \
    || ok "下载页没再提 release.zip"

# 只有源码包的机器：下载 → 解包 → **源码铺回项目目录**（否则 install 没东西可装）
P6="$T/ws6/shell/zsh"
export WTOOL_ROOT="$T/ws6"
mkdir -p "$P6/__release"
cp "$P5/__release/dist.json" "$P6/__release/"
cp "$P5/__release/源码.zip" "$P6/__release/"
"$WT" unpack-release "$P6" > "$T/unpack6.log" 2>&1 \
    || bad "只有源码包也能 unpack" "$(cat "$T/unpack6.log")"
[ -f "$P6/wtool.xml" ] && ok "源码铺回项目目录了（wtool.xml 到位）" \
    || bad "wtool.xml 没铺出来" "$(cat "$T/unpack6.log")"
[ -f "$P6/env.zsh" ] && ok "env.zsh 也铺回来了（声明面指向的文件得在）" \
    || bad "env.zsh 没铺出来"
[ -e "$P6/__output" ] && bad "凭空造了 __output/（这个项目本来就没有产物）" \
    || ok "没有凭空造 __output/"
[ -f "$T/ws6/.wtool-dist/shell-zsh.json" ] \
    && ok "发布副本标记铺到工作区根（解压副本没有 .git 时 install 靠它免 --force）" \
    || bad "没铺 .wtool-dist 标记"
grep -q '源码就是产物' "$T/unpack6.log" \
    && ok "unpack 说清了走的是「只有源码包」那条路" \
    || bad "unpack 没说清" "$(cat "$T/unpack6.log")"

# 对照：**有构建能力**的项目，源码包依旧只校验、不铺开（行为一字不改）
#   自己造一个小项目，不依赖上面任何一个（场景 2 把 $P 的包切成卷了）
P6c="$T/ws6c/acme/app"; export WTOOL_ROOT="$T/ws6c"
mkdir -p "$P6c/scripts" "$P6c/__output/bin" "$P6c/src"
printf 'true\n'                     > "$P6c/scripts/build.sh"
printf '#!/bin/sh\necho hi\n'       > "$P6c/__output/bin/tool"
chmod +x "$P6c/__output/bin/tool"
printf '只在本机、包外的东西\n'      > "$P6c/src/keep.txt"
cat > "$P6c/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="50"/>
EOF
printf '__output/\n__release/\n' > "$P6c/.gitignore"
git -C "$P6c" init -q && git -C "$P6c" add -A \
    && git -C "$P6c" -c user.name=t -c user.email=t@t commit -qm init
"$WT" pack-release "$P6c" --tag=v1 --repo=fakeowner/app > "$T/pack6c.log" 2>&1 \
    || bad "对照项目 pack-release" "$(cat "$T/pack6c.log")"
[ -f "$P6c/__release/release.zip" ] && ok "对照：有构建能力的项目照常两个包" \
    || bad "对照：release.zip 没产出"
[ -f "$P6c/__release/release-hash.txt" ] && ok "对照：release-hash.txt 也在" \
    || bad "对照：release-hash.txt 没产出"
# 换一台"新机器"（没有 src/），只放包 → 源码包不该被铺开
P6d="$T/ws6d/acme/app"; export WTOOL_ROOT="$T/ws6d"
mkdir -p "$P6d/__release"
cp "$P6c/__release/"* "$P6d/__release/"
"$WT" unpack-release "$P6d" > "$T/unpack6d.log" 2>&1 \
    || bad "对照 unpack" "$(cat "$T/unpack6d.log")"
[ -f "$P6d/__output/bin/tool" ] && ok "对照：产物解出来了（__output/）" \
    || bad "对照：产物没解出来"
[ -e "$P6d/src" ] && bad "对照：源码包被错误铺开了（src/ 凭空出现）" \
    || ok "对照：源码包**没有**被铺开（有构建能力的项目行为未变）"
grep -q '源码包校验通过（不铺开）' "$T/unpack6d.log" \
    && ok "对照：日志说的还是「只校验、不铺开」" || bad "对照：日志变了"

# --------------------------------------------------------------------------
printf '\n== 场景 5：dry-run 不产文件 ==\n'
P7="$T/ws7/p"
export WTOOL_ROOT="$T/ws7"
mkdir -p "$P7/scripts" "$P7/__output"
printf 'x\n' > "$P7/__output/x.bin"
printf 'true\n' > "$P7/scripts/build.sh"
cat > "$P7/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="50"/>
EOF
git -C "$P7" init -q && git -C "$P7" add -A \
    && git -C "$P7" -c user.name=t -c user.email=t@t commit -qm init
"$WT" pack-release "$P7" --dry-run --tag=v1 --repo=o/r > "$T/pack7.log" 2>&1 \
    || bad "dry-run 执行" "$(cat "$T/pack7.log")"
[ ! -d "$P7/__release" ] && ok "dry-run 不建 __release/" || bad "dry-run 建了 __release/"
grep -q 'dry-run' "$T/pack7.log" && ok "dry-run 输出了计划" || bad "dry-run 没输出计划"
[ ! -f "$P7/scripts/downloads.sh" ] && ok "dry-run 不写 downloads.sh（它本来也不该存在）" \
    || bad "dry-run 写了 downloads.sh"

# --------------------------------------------------------------------------
printf '\n== 场景 6：download-release 读**提交的** release.json 把包下回来（不联网）==\n'
#   这是"另一台机器"那条路：仓库里有 scripts/release.json（提交过的声明），
#   __release/ 和 __output/ 都还没有。把 base_url 指到本地目录，用 file:// 假装发布页
#   —— 全程不联网，但走的是同一段"下载 + sha256 校验"的代码。
P8="$T/ws8/terminal/tmux"
export WTOOL_ROOT="$T/ws8"
mkdir -p "$P8/scripts" "$P8/__output/ubuntu_24.04/bin" "$T/pub8"
printf 'bin\n' > "$P8/__output/ubuntu_24.04/bin/tmux"
chmod +x "$P8/__output/ubuntu_24.04/bin/tmux"
printf 'set -g mouse on\n' > "$P8/tmux.conf"
printf 'export DEMO=1\n' > "$P8/env.zsh"
printf 'export DEMO=1\n' > "$P8/env.bash"
cat > "$P8/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="50"/>
EOF
printf '__output/\nrelease/\n' > "$P8/.gitignore"
printf '#!/bin/sh\ntrue\n' > "$P8/scripts/build.sh"
git -C "$P8" init -q && git -C "$P8" add -A \
    && git -C "$P8" -c user.name=t -c user.email=t@t commit -qm init
"$WT" pack-release "$P8" --tag=v8 --repo=fakeowner/tmux > "$T/pack8.log" 2>&1 \
    || bad "场景 6 的 pack-release" "$(cat "$T/pack8.log")"
# 假装那些资产已经挂在发布页上
cp -f "$P8"/__release/*.zip "$P8"/__release/dist.json "$P8"/__release/*-hash.txt "$T/pub8/" 2>/dev/null || true
# 生成"提交进仓库"的声明（真流程里由 publish-release 写），再把 base_url 指到本地
py "$boot/lib/wtool_plan.py" release-json --release-dir "$P8/__release" \
    --dist "$P8/__release/dist.json" --project-id terminal/tmux --engine 1.0.0 \
    --at 2026-01-01T00:00:00+0800 --dirty 0 --targets ubuntu_24.04 > "$P8/scripts/release.json" \
    || bad "生成 release.json"
py - "$P8/scripts/release.json" "$T/pub8" <<'PY'
import json, sys
p, base = sys.argv[1], sys.argv[2]
d = json.load(open(p, encoding="utf-8"))
d["base_url"] = "file://" + base
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
git -C "$P8" add -A && git -C "$P8" -c user.name=t -c user.email=t@t commit -qm 'release.json'

# ★ 新机器：产物和包都没有
rm -rf "$P8/__release" "$P8/__output"
_rc=0
"$WT" download-release "$P8" > "$T/dl8.log" 2>&1 || _rc=$?
chk "download-release 执行成功" "$_rc" "0"
[ -f "$P8/__release/release.zip" ] && ok "release.zip 下回来了" \
    || bad "release.zip 没下来" "$(tail -5 "$T/dl8.log")"
[ -f "$P8/__release/dist.json" ] && ok "dist.json 也下回来了（unpack 要用它）" || bad "dist.json 没下来"
check "__release/.source 标成 downloaded（publish-release 靠它拒收）" "downloaded" \
    "$(cut -f1 < "$P8/__release/.source" 2>/dev/null || echo 无)"
chk "下回来的 release.zip 逐字节一致" "$(zsha "$P8/__release/release.zip")" "$(zsha "$T/pub8/release.zip")"

# 幂等：再下一次，应该全部跳过（不是重新下）
_rc=0
"$WT" download-release "$P8" > "$T/dl8b.log" 2>&1 || _rc=$?
chk "第二次 download-release 也成功（幂等）" "$_rc" "0"
grep -q '已是最新，跳过' "$T/dl8b.log" && ok "已经下好的文件被跳过（没重下）" \
    || bad "第二次没有跳过" "$(tail -4 "$T/dl8b.log")"

# sha256 对不上 → 不许把坏文件留在 __release/
cp -f "$T/pub8/release.zip" "$T/pub8/release.zip.good"     # 留一份好的，下面换回来
printf 'corrupt\n' > "$T/pub8/release.zip"
rm -f "$P8/__release/release.zip"
"$WT" download-release "$P8" > "$T/dl8c.log" 2>&1 || true
[ ! -f "$P8/__release/release.zip" ] && ok "sha256 对不上的文件没被留在 __release/" \
    || bad "坏文件被当成好文件放进 __release/ 了"

# 把发布页上的文件换回好的，再下一次 —— 应该能下回来，然后才解包
mv -f "$T/pub8/release.zip.good" "$T/pub8/release.zip"
"$WT" download-release "$P8" > "$T/dl8d.log" 2>&1 || true
[ -f "$P8/__release/release.zip" ] && ok "发布页恢复之后能重新下回来" \
    || bad "重新下载失败" "$(tail -4 "$T/dl8d.log")"
"$WT" unpack-release "$P8" > "$T/unpack8.log" 2>&1 || true
[ -x "$P8/__output/ubuntu_24.04/bin/tmux" ] && ok "unpack-release 把产物解了出来（可执行位也在）" \
    || bad "download → unpack 之后 __output/ 不对" "$(tail -5 "$T/unpack8.log")"
[ -f "$P8/wtool.xml" ] && [ -f "$P8/env.bash" ] && ok "声明面回到项目根" || bad "声明面没回来"

# --------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'release_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
