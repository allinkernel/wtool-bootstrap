#!/bin/sh
# layer_test.sh —— `layer/<target>/` 那棵 OCI 镜像目录（ADR-024 / BL-27）
#
# 全程在临时目录里跑：**不联网、不碰真 docker、不碰真 $HOME / 真工作区**。
# docker 是打桩的（`$T/bin/docker`）：save 吐预先造好的 OCI tar，load 把 stdin 落盘。
# 验证点：
#   1. 写：`docker save | tar -x` 之后 layer/<target>/ 是一棵**目录**
#      （blobs/sha256/… + index.json + oci-layout）
#   2. **去重**：两个共享父链的镜像存进同一棵 layout，那个 blob 只留一份
#   3. **index 合并**：第二个进来不把第一个的条目弄丢（annotation 里记层名）
#   4. 读：喂给 `docker load` 的 tar 里有 oci-layout / index.json / 全部 blob
#   5. `layer/` 默认不存在；dry-run 不建它
#   6. `pack-layer` 已删除：die + 指路
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(dirname -- "$here")
WT="$boot/wtool.sh"

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"
         if [ $# -gt 1 ]; then printf '      %s\n' "$2"; fi; return 0; }
chk()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$3]  实际 [$2]"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-layer.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

# 环境里继承来的 WTOOL_* 会指到真 $HOME / 真工作区，先清掉
for _v in $(env | grep -o '^WTOOL_[A-Za-z_]*'); do unset "$_v"; done
export WTOOL_ROOT="$T/ws" WTOOL_STATE="$T/state" WTOOL_HOME="$T/home"
mkdir -p "$WTOOL_ROOT/terminal/demo/scripts" "$WTOOL_ROOT/terminal/demo/output/ubuntu_24.04" \
         "$WTOOL_STATE" "$WTOOL_HOME" "$T/bin"

P="$WTOOL_ROOT/terminal/demo"
cat > "$P/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="terminal/demo" priority="50"/>
EOF
printf 'output/\nrelease/\n' > "$P/.gitignore"
git -C "$P" init -q && git -C "$P" add -A \
    && git -C "$P" -c user.name=t -c user.email=t@t commit -qm init

# ── 造两份"docker save 出来"的 OCI tar：共享一个 blob（模拟共享父链）────────
mk_save() {   # <文件> <独有 blob 名> <manifest digest>
    _d="$T/mk.$2"; mkdir -p "$_d/blobs/sha256"
    printf '{"imageLayoutVersion":"1.0.0"}\n' > "$_d/oci-layout"
    printf 'parent-layer\n'  > "$_d/blobs/sha256/parent0000"
    printf '%s\n' "$2"       > "$_d/blobs/sha256/$2"
    printf '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":10}]}\n' \
        "$3" > "$_d/index.json"
    tar -cf "$1" -C "$_d" oci-layout index.json blobs
    rm -rf -- "$_d"
}
mk_save "$T/saveA.tar" blobAAAA sha256:aaaa1111
mk_save "$T/saveB.tar" blobBBBB sha256:bbbb2222

# ── 打桩 docker ────────────────────────────────────────────────────────────
cat > "$T/bin/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/docker.log"
case "\$1" in
    image) exit 0 ;;
    save)  case "\$2" in
               imgA) cat "$T/saveA.tar" ;;
               imgB) cat "$T/saveB.tar" ;;
           esac ;;
    load)  cat > "$T/loaded.tar" ;;
esac
exit 0
EOF
chmod +x "$T/bin/docker"
PATH="$T/bin:$PATH"
export PATH
: > "$T/docker.log"

L="$P/layer/ubuntu_24.04"

# --------------------------------------------------------------------------
printf '\n== 1. layer-save：docker 镜像 → layer/<target>/ ==\n'
echo hi > "$P/output/ubuntu_24.04/x.bin"        # 让 --target 能推出来
"$WT" layer-save terminal/demo --image=imgA > "$T/s1.log" 2>&1 \
    || bad "layer-save imgA" "$(cat "$T/s1.log")"
[ -f "$L/oci-layout" ] && ok "oci-layout 建出来了" || bad "没有 oci-layout"
[ -f "$L/index.json" ] && ok "index.json 建出来了" || bad "没有 index.json"
chk "第一次进来有 2 个 blob（parent + 自己的）" "2" \
    "$(ls "$L/blobs/sha256" | wc -l | tr -d ' ')"
cat "$T/docker.log" | grep -q '^save imgA$' && ok "走的是 docker save" || bad "没调 docker save"

printf '\n== 2. 第二个镜像进来：blob 去重 + index 合并 ==\n'
"$WT" layer-save terminal/demo --image=imgB --layer=lang/demo > "$T/s2.log" 2>&1 \
    || bad "layer-save imgB" "$(cat "$T/s2.log")"
chk "★共享的父层只留一份（2 + 2 - 1 = 3）" "3" \
    "$(ls "$L/blobs/sha256" | wc -l | tr -d ' ')"
chk "★index.json 里两个 manifest 都在（没被覆盖）" "2" \
    "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1],encoding="utf-8"))["manifests"]))' "$L/index.json")"
chk "annotation 记了层名（含 lang/demo 这种带斜杠的）" "lang/demo" \
    "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print([m["annotations"]["io.wtool.layer"] for m in d["manifests"] if m["annotations"]["io.wtool.layer"]=="lang/demo"][0])' "$L/index.json")"
chk "annotation 记了 target" "ubuntu_24.04" \
    "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print(d["manifests"][0]["annotations"]["io.wtool.target"])' "$L/index.json")"

printf '\n== 3. layer-load：装回 docker（tar 只当管道）==\n'
"$WT" layer-load terminal/demo > "$T/l1.log" 2>&1 || bad "layer-load" "$(cat "$T/l1.log")"
[ -f "$T/loaded.tar" ] && ok "喂给了 docker load" || bad "docker load 没收到东西"
chk "喂过去的 tar 里有 oci-layout / index.json / 3 个 blob" "5" \
    "$(tar -tf "$T/loaded.tar" | grep -E '^\./(oci-layout|index.json)$|^\./blobs/sha256/.+$' |
       grep -vc '/$' || true)"

printf '\n== 4. layer/ 默认不存在 + dry-run 不建它 ==\n'
rm -rf "$P/layer"
"$WT" layer-save terminal/demo --image=imgA --dry-run > "$T/s3.log" 2>&1 \
    || bad "dry-run" "$(cat "$T/s3.log")"
grep -q 'dry-run' "$T/s3.log" && ok "dry-run 打了计划" || bad "dry-run 没打计划"
[ -d "$P/layer" ] && bad "dry-run 建了 layer/" || ok "dry-run 不建 layer/"

printf '\n== 5. pack-layer 已删除（die + 指路）==\n'
_rc=0
"$WT" pack-layer terminal/demo --layer=main > "$T/pl.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "pack-layer 退出码非 0" || bad "pack-layer 居然还能跑"
grep -q 'layer-save' "$T/pl.log" && grep -q 'unpack-layer' "$T/pl.log" \
    && ok "指了路（layer-save / unpack-layer）" || bad "没指路" "$(cat "$T/pl.log")"

# --------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'layer_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
