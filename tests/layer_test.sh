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
#   7. `unpack-layer`：blob → output/<target>/<层>/{payload,OWNED.tsv}（不联网、不要 docker）
#   8. `push-layer`：docker tag + docker push（缺 io.wtool.image 的条目直接失败，不推半截）
#   9. `pull-layer`：skopeo copy → layer/<target>/，层名从 tag 还原、annotation 补上
#  10. 老名字 `push-layers` / `pull-layers` die + 指路
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
mk_save "$T/saveC.tar" blobCCCC sha256:cccc3333      # 带 tag 的那个镜像名用（digest 必须不同，
                                                     # 同 digest 会被"已存在"跳过 —— 这正是去重）

# ── 打桩 docker ────────────────────────────────────────────────────────────
cat > "$T/bin/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/docker.log"
case "\$1" in
    image) exit 0 ;;
    save)  case "\$2" in
               imgA) cat "$T/saveA.tar" ;;
               imgB) cat "$T/saveB.tar" ;;
               *:1.2) cat "$T/saveC.tar" ;;   # 带 tag 的名字：验默认层名会不会把冒号带进来
           esac ;;
    load)  cat > "$T/loaded.tar" ;;   # `$*` 就是 "load"，日志里那一行由上面统一记
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

# 层名不给时从镜像名推 —— **冒号必须去掉**：层名最后要当 docker tag，
# `nvim_base:ubuntu_22.04` 会拼出一个非法的 tag（push 直接 "invalid reference format"）
"$WT" layer-save terminal/demo --image=reg.example.com/ns/imgC:1.2 > "$T/s4.log" 2>&1 \
    || bad "layer-save（带 tag 的镜像名）" "$(cat "$T/s4.log")"
chk "★层名不给时从镜像名推，且去掉了 tag" "imgC" \
    "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print([ (m.get("annotations") or {}).get("io.wtool.layer","")
        for m in d["manifests"]
        if (m.get("annotations") or {}).get("io.wtool.image")=="reg.example.com/ns/imgC:1.2"][0])' \
       "$L/index.json")"

printf '\n== 3. layer-load：装回 docker（tar 只当管道）==\n'
"$WT" layer-load terminal/demo > "$T/l1.log" 2>&1 || bad "layer-load" "$(cat "$T/l1.log")"
[ -f "$T/loaded.tar" ] && ok "喂给了 docker load" || bad "docker load 没收到东西"
chk "喂过去的 tar 里有 oci-layout / index.json / 全部 blob" \
    "$(( $(ls "$L/blobs/sha256" | wc -l) + 2 ))" \
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

[ "$fail" -eq 0 ] || exit 1

# --------------------------------------------------------------------------
printf '\n== 6. unpack-layer：读 blob → output/（不需要 docker）==\n'
#   手造一层真 blob：容器里的形状是 root/.wtool/**（影子 $HOME），
#   解开时要剥掉前两节、丢掉白障、再扫目录生成 OWNED.tsv。
# 第 4 节把整棵 layout 删了（dry-run 那条）—— 这里重新走一遍**真的** layer-save
"$WT" layer-save terminal/demo --image=imgA > "$T/s1b.log" 2>&1 \
    || bad "layer-save imgA（重建）" "$(cat "$T/s1b.log")"
"$WT" layer-save terminal/demo --image=imgB --layer=lang/demo > "$T/s2b.log" 2>&1 \
    || bad "layer-save imgB（重建）" "$(cat "$T/s2b.log")"
mkdir -p "$T/real/root/.wtool/usr/bin" "$T/real/root/.wtool/.local/share/demo/log"
printf '#!/bin/sh\necho hi\n' > "$T/real/root/.wtool/usr/bin/demo"; chmod +x "$T/real/root/.wtool/usr/bin/demo"
ln -s demo "$T/real/root/.wtool/usr/bin/demo-link"          # 相对软链（payload 内，合法）
printf 'junk\n' > "$T/real/root/.wtool/.local/share/demo/log/x.log"
( cd "$T/real" && tar -czf "$T/layer.tgz" root )
_bsha=$(sha256sum "$T/layer.tgz" | cut -d' ' -f1)
cp "$T/layer.tgz" "$L/blobs/sha256/$_bsha"
printf '{"layers":[{"digest":"sha256:%s"}]}\n' "$_bsha" > "$T/manifest.json"
_msha=$(sha256sum "$T/manifest.json" | cut -d' ' -f1)
cp "$T/manifest.json" "$L/blobs/sha256/$_msha"
python3 -c '
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding="utf-8"))
d["manifests"].append({"mediaType":"application/vnd.oci.image.manifest.v1+json",
                       "digest":"sha256:"+sys.argv[2],"size":100,
                       "annotations":{"io.wtool.layer":"main","io.wtool.target":"ubuntu_24.04",
                                      "io.wtool.image":"imgMain"}})
json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)' "$L/index.json" "$_msha"

rm -rf "$P/output/ubuntu_24.04"
"$WT" unpack-layer terminal/demo --layer=main > "$T/ul.log" 2>&1 \
    || bad "unpack-layer" "$(cat "$T/ul.log")"
O="$P/output/ubuntu_24.04/main"
[ -x "$O/payload/usr/bin/demo" ] && ok "blob 解成了 output/<target>/<层>/payload（可执行位也在）" \
    || bad "payload 不对" "$(cat "$T/ul.log")"
[ -L "$O/payload/usr/bin/demo-link" ] && ok "payload 里的软链还是软链" || bad "软链丢了"
[ -s "$O/OWNED.tsv" ] && ok "OWNED.tsv 扫出来了" || bad "没有 OWNED.tsv"
chk "OWNED.tsv 三列、层名是 main" "main" \
    "$(awk -F'\t' 'END{print $3}' "$O/OWNED.tsv")"
chk "软链记成 L:<原值>（不是跟随目标算 sha256）" "L:demo" \
    "$(awk -F'\t' '$1=="usr/bin/demo-link"{print $2}' "$O/OWNED.tsv")"
chk "普通文件记的是 sha256" "$(sha256sum "$O/payload/usr/bin/demo" | cut -d' ' -f1)" \
    "$(awk -F'\t' '$1=="usr/bin/demo"{print $2}' "$O/OWNED.tsv")"

# ★ OWNED.tsv 里**不许**出现扫描器自己的临时文件（它扫完就删了，留着会让 install
#   去校验一个不存在的文件）。2026-09-28 用真 astronvim 的层彩排时现的原形：每层都多 1 条。
chk "★OWNED.tsv 里没有扫描器的临时文件" "0" \
    "$(grep -c 'escaping-links' "$O/OWNED.tsv" 2>/dev/null || true)"
chk "payload 里也没有它" "0" \
    "$(find "$O/payload" -name '.escaping-links*' | wc -l | tr -d ' ')"

printf '\n== 7. 指向 payload 外面的软链 = 这一层不能用（直接失败）==\n'
mkdir -p "$T/bad/root/.wtool/usr/bin"
ln -s /etc/hostname "$T/bad/root/.wtool/usr/bin/escape"
( cd "$T/bad" && tar -czf "$T/bad.tgz" root )
_bsha2=$(sha256sum "$T/bad.tgz" | cut -d' ' -f1)
cp "$T/bad.tgz" "$L/blobs/sha256/$_bsha2"
printf '{"layers":[{"digest":"sha256:%s"}]}\n' "$_bsha2" > "$T/manifest2.json"
_msha2=$(sha256sum "$T/manifest2.json" | cut -d' ' -f1)
cp "$T/manifest2.json" "$L/blobs/sha256/$_msha2"
python3 -c '
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding="utf-8"))
d["manifests"].append({"mediaType":"application/vnd.oci.image.manifest.v1+json",
                       "digest":"sha256:"+sys.argv[2],"size":100,
                       "annotations":{"io.wtool.layer":"bad","io.wtool.target":"ubuntu_24.04"}})
json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)' "$L/index.json" "$_msha2"
_rc=0
"$WT" unpack-layer terminal/demo --layer=bad > "$T/bad.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "指到包外面的软链让它失败了" || bad "居然装上了（换台机器必定悬空）"
grep -q '悬空' "$T/bad.log" && ok "说清了为什么不能要" || bad "没说清原因" "$(cat "$T/bad.log")"

printf '\n== 8. push-layer：layer/<target>/ → 镜像仓库（docker tag + docker push）==\n'
#   第 7 节往 index.json 里塞了一个没有 io.wtool.image 的条目（手造的）——
#   推到最后会撞上它，正好验"半截不推"。
: > "$T/docker.log"
export WTOOL_LAYER_REGISTRY="reg.example.com/ns"
_rc=0
"$WT" push-layer terminal/demo --target=ubuntu_24.04 > "$T/push.log" 2>&1 || _rc=$?
chk "先 docker load 了整棵 layout" "1" "$(grep -c '^load$' "$T/docker.log")"
grep -q '^tag imgA reg.example.com/ns/demo:imgA-ubuntu_24.04$' "$T/docker.log" \
    && ok "docker tag 成 <仓库>/<项目>:<层>-<target>" || bad "tag 不对" "$(cat "$T/docker.log")"
grep -q '^push reg.example.com/ns/demo:lang-demo-ubuntu_24.04$' "$T/docker.log" \
    && ok "层名里的 / 换成 - 再当 tag 推" || bad "lang/demo 的 tag 不对" "$(cat "$T/docker.log")"
chk "推了 3 个层（imgA / lang-demo / main）" "3" "$(grep -c '^push ' "$T/docker.log")"
[ "$_rc" != 0 ] && ok "有条目不知道对应哪个镜像 → 直接失败，不推半截" || bad "居然当成功了"
grep -q 'layer-save' "$T/push.log" && ok "指了路（重新 layer-save 一次）" || bad "没指路" "$(cat "$T/push.log")"

printf '\n== 9. pull-layer：镜像仓库 → layer/<target>/（stub skopeo，不联网）==\n'
rm -rf "$P/layer"                       # 从"全新机器"开始：连 layer/ 都没有
cat > "$T/mkentry.py" <<'PYEOF'
import json, os, sys
lay, tag = sys.argv[1], sys.argv[2]
p = os.path.join(lay, "index.json")
try:
    with open(p, encoding="utf-8") as fh:
        idx = json.load(fh)
except Exception:
    idx = {"schemaVersion": 2, "manifests": []}
idx["manifests"] = [m for m in idx.get("manifests", [])
                    if (m.get("annotations") or {}).get("org.opencontainers.image.ref.name") != tag]
idx["manifests"].append({"mediaType": "application/vnd.oci.image.manifest.v1+json",
                         "digest": "sha256:fake" + tag.replace("/", "_"), "size": 1,
                         "annotations": {"org.opencontainers.image.ref.name": tag}})
with open(p, "w", encoding="utf-8") as fh:
    json.dump(idx, fh, ensure_ascii=False, indent=2)
PYEOF
# skopeo 打桩：list-tags 读固定表；copy 就按 skopeo 的行为往 oci: 目录里**追加**一个条目
cat > "$T/bin/skopeo" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/skopeo.log"
case "\$1" in
    list-tags) cat "$T/tags.json" ;;
    copy)
        _dst=\$4; _dir=\${_dst#oci:}; _tag=\${_dst##*:}; _dir=\${_dir%:*}
        mkdir -p "\$_dir/blobs/sha256"
        [ -f "\$_dir/oci-layout" ] || printf '{"imageLayoutVersion":"1.0.0"}\n' > "\$_dir/oci-layout"
        python3 "$T/mkentry.py" "\$_dir" "\$_tag"
        ;;
esac
exit 0
EOF
chmod +x "$T/bin/skopeo"
cat > "$T/tags.json" <<'EOF'
{"Repository":"reg.example.com/ns/demo",
 "Tags":["main-ubuntu_24.04","lang-demo-ubuntu_24.04","other-ubuntu_22.04"]}
EOF
entries_of() { python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for m in d["manifests"]:
    a = m.get("annotations") or {}
    print("%s\t%s\t%s" % (a.get("io.wtool.layer", ""), a.get("io.wtool.target", ""),
                          a.get("io.wtool.image", "")))' "$1"; }
: > "$T/skopeo.log"
"$WT" pull-layer terminal/demo --target=ubuntu_24.04 --registry=reg.example.com/ns \
    > "$T/pull.log" 2>&1 || bad "pull-layer" "$(cat "$T/pull.log")"
chk "只拉这个 target 的 tag（另一个 target 的不碰）" "2" "$(grep -c '^copy ' "$T/skopeo.log")"
chk "★层名还原：lang-demo → lang/demo" "lang/demo" \
    "$(entries_of "$P/layer/ubuntu_24.04/index.json" | awk -F'\t' '$3 ~ /:lang-demo-/{print $1}')"
chk "拉回来的条目记了 target" "ubuntu_24.04" \
    "$(entries_of "$P/layer/ubuntu_24.04/index.json" | awk -F'\t' '$3 ~ /:main-/{print $2}')"
chk "拉回来的条目记了来源（镜像名 = docker://…）" "docker://reg.example.com/ns/demo:main-ubuntu_24.04" \
    "$(entries_of "$P/layer/ubuntu_24.04/index.json" | awk -F'\t' '$3 ~ /:main-/{print $3}')"
: > "$T/skopeo.log"
"$WT" pull-layer terminal/demo --target=ubuntu_24.04 --registry=reg.example.com/ns --layer=main \
    > "$T/pull2.log" 2>&1 || bad "pull-layer --layer=main" "$(cat "$T/pull2.log")"
chk "--layer= 只拉那一个" "1" "$(grep -c '^copy ' "$T/skopeo.log")"
chk "--layer= 比的是还原后的层名（main）" "1" \
    "$(grep -c '^copy --all docker://reg.example.com/ns/demo:main-ubuntu_24.04' "$T/skopeo.log")"

printf '\n== 10. 老名字 push-layers / pull-layers：die + 指路 ==\n'
for _old in push-layers pull-layers; do
    _rc=0
    "$WT" "$_old" terminal/demo > "$T/old-$_old.log" 2>&1 || _rc=$?
    [ "$_rc" != 0 ] && ok "$_old 退出码非 0" || bad "$_old 居然还能跑"
    grep -q -- "-layer" "$T/old-$_old.log" && ok "$_old 指了路" \
        || bad "$_old 没指路" "$(cat "$T/old-$_old.log")"
done

printf '\n----------------------------------------\n'
printf 'layer_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
