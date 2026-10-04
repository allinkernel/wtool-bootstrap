#!/bin/sh
# docker_build_test.sh —— kind="docker" 的**引擎驱动构建**（ADR-0025 §3 / ADR-0029）
#
# 全程在临时目录里跑：**不联网、不碰真 docker、不碰真 $HOME / 真工作区**。
# docker 是打桩的（`$T/bin/docker`），它模拟：
#   image inspect   镜像在不在（一张 "已 commit" 的表）
#   run -d          起容器（记下容器名）
#   exec -d         把引擎写的那份 **.run 包装脚本真的跑一遍**（cwd 换成项目目录），
#                   记下这次跑出来的文件 = 这一层的增量，再写 EXIT=
#   commit          照增量打一份 "docker save 出来" 的 OCI tar（顶层 blob = 这一层）
#   save / load / ps / rm / volume
#
# 卡点在于 exec 真的执行那一层的东西：所以"每层装了什么"是真写出来的，
# 引擎随后的 import / export 也就有真东西可搬 —— 这不是"调用次数"式的空转测试。
# 验证点：
#   1. 引擎按 build/targets.tsv + build/layers.tsv 起容器、commit、落 __layer/、导 __output/
#   2. **一层镜像对一层 output**：每层 payload 里只有它自己那层的文件
#   3. 续跑：镜像在 docker 里就不重起容器；layout/output 齐了就不重复 save/导出
#   4. 父层不在 docker 里 → 从 __layer/ 装回来（docker 存储只是缓存）
#   5. 容器里失败 → 这一层不出、不 commit、退出码非 0、日志尾部贴出来
#   6. 占位层（镜像名 -）留一个空的 output 层
#   7. build/export.filter 真的过滤掉了东西
#   8. --dry-run 一个字节不写
#   9. 并行：父层就绪的兄弟层同时跑（BL-34）
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(dirname -- "$here")
WT="$boot/wtool.sh"
PY="$boot/lib/wtool_plan.py"

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"
         if [ $# -gt 1 ]; then printf '      %s\n' "$2"; fi; return 0; }
chk()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$3]  实际 [$2]"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-dbuild.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM
for _v in $(env | grep -o '^WTOOL_[A-Za-z_]*'); do unset "$_v"; done
export WTOOL_ROOT="$T/ws" WTOOL_STATE="$T/state" WTOOL_HOME="$T/home"
mkdir -p "$WTOOL_STATE" "$WTOOL_HOME" "$T/bin" "$T/fix" "$T/diff" "$T/fakeroot"

P="$WTOOL_ROOT/editor/demo"
mkdir -p "$P/build" "$P/scripts"
cat > "$P/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="50"><build kind="docker"/></wtool>
EOF
cat > "$P/build/targets.tsv" <<'EOF'
# 目标系统	基础镜像
ubuntu_24.04	base:24.04
EOF
cat > "$P/build/layers.tsv" <<'EOF'
# 层名	父层	镜像名	容器里跑的命令
one	-	demo/one	sh /proj/scripts/layer.sh one {target}
two	one	demo/two	sh /proj/scripts/layer.sh two {target}
three	two	demo/three	sh /proj/scripts/layer.sh three {target}
other	two	demo/other	sh /proj/scripts/layer.sh other {target}
empty	two	-	-
EOF
cat > "$P/build/export.filter" <<'EOF'
# 导出时丢掉的东西（一行一个 tar --exclude 通配）
*.log
EOF
# "容器里"跑的东西：往影子 $HOME 放文件，再留一个白障（模拟删掉了东西）
cat > "$P/scripts/layer.sh" <<'EOF'
#!/bin/sh
set -e
L=$1
# 兄弟层（three / other 都挂在 two 下面）慢一点 —— 量"有没有真的并行"
if [ "${WTOOL_TEST_SLOW:-}" = 1 ]; then sleep 2; fi
D="$WTOOL_TEST_ROOT/root/.wtool/usr/share/$L"
mkdir -p "$D"
printf '%s\n' "$L" > "$D/file.txt"
printf 'junk\n' > "$D/skip.log"
: > "$D/.wh.deleted"
EOF
chmod +x "$P/scripts/layer.sh"

# ── 打桩 docker ─────────────────────────────────────────────────────────────
cat > "$T/bin/docker" <<'DEOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1" in
    image)
        [ "$2" = inspect ] || exit 0
        _ref=$3
        if [ "$_ref" = "--format" ]; then
            _ref=$5
            case "$4" in
                *RepoDigests*)
                    printf 'demo/base@sha256:%s\n' \
                        "$(printf '%s' "$_ref" | tr -c 'A-Za-z0-9' 'a' | cut -c1-16)"
                    exit 0 ;;
                *'.Id'*)
                    printf 'sha256:%s\n' \
                        "id$(printf '%s' "$_ref" | tr -c 'A-Za-z0-9' 'a' | cut -c1-12)"
                    exit 0 ;;
            esac
            exit 1
        fi
        grep -qx -- "$_ref" "$DOCKER_IMAGES" 2>/dev/null && exit 0 || exit 1 ;;
    volume) exit 0 ;;
    load)
        # 引擎是 `tar -c -C 布局 . | docker load`：真 load 会把布局里的镜像装回来，
        # 桩也得这么干 —— 否则"从 __layer/ 恢复"那条路会退化成"重编一遍"（测不到真东西）
        cat > "$DOCKER_TMP/loaded.tar"
        tar -xOf "$DOCKER_TMP/loaded.tar" ./index.json 2>/dev/null \
          | python3 -c '
import json,sys
for m in json.load(sys.stdin).get("manifests", []):
    ref = (m.get("annotations") or {}).get("org.opencontainers.image.ref.name")
    if ref:
        print(ref)' >> "$DOCKER_IMAGES" 2>/dev/null || true
        exit 0 ;;
    ps)     cat "$DOCKER_PS" 2>/dev/null; exit 0 ;;
    run)
        _name=""
        for _a in "$@"; do
            [ "$_prev" = "--name" ] && _name=$_a
            _prev=$_a
        done
        printf '%s\n' "$_name" > "$DOCKER_PS"
        exit 0 ;;
    exec)
        # exec -d <容器> sh -c "sh /log/<slug>.run > /log/<slug>.log 2>&1; echo EXIT=$? >> ..."
        _ctr=$3; _script=$6
        # 引擎给的是**容器里的**路径（/log/…）—— 桩在宿主机上，映射到 $LOG_DIR
        _run="$LOG_DIR/$(basename "$(printf '%s' "$_script" | sed 's/^sh //; s/ > .*//')")"
        _out="$LOG_DIR/$(basename "$(printf '%s' "$_script" | sed 's/^.*> //; s/ 2>&1.*//')")"
        : > "$_out"
        # 把包装脚本里的 `cd /proj` 换成本机上的项目目录 —— 桩没有容器
        # 容器里的 /proj 是挂载点、/log 也是挂载点、/wtool-layer 是层里的。
        # 桩在宿主机上，把这三个都换成本机路径（等价于"容器真的这么跑"）
        # ⚠️ 每容器一份：并行时两个 exec 会同时在跑，共用一个文件名会互相踩
        #    （实测：diff 被对方清掉 → 有一层的 payload 是空的）
        _fake="$DOCKER_TMP/fake.$_ctr.run"
        sed -e "s|/wtool-layer|$WTOOL_TEST_ROOT/wtool-layer|g" \
            -e "s|/log|$LOG_DIR|g" \
            -e "s|/proj|$DOCKER_PROJ|g" "$_run" > "$_fake"
        _before="$DOCKER_TMP/before.$_ctr"; _after="$DOCKER_TMP/after.$_ctr"
        ( cd "$WTOOL_TEST_ROOT" && find . \( -type f -o -type l \) 2>/dev/null |
              sed 's|^\./||' | LC_ALL=C sort ) > "$_before"
        _rc=0
        printf '%s\t%s\n' "start" "$(basename "$_run" .run)" >> "$DOCKER_TIMELINE"
        WTOOL_TEST_ROOT="$WTOOL_TEST_ROOT" sh "$_fake" >> "$_out" 2>&1 || _rc=$?
        printf '%s\t%s\n' "end" "$(basename "$_run" .run)" >> "$DOCKER_TIMELINE"
        ( cd "$WTOOL_TEST_ROOT" && find . \( -type f -o -type l \) 2>/dev/null |
              sed 's|^\./||' | LC_ALL=C sort ) > "$_after"
        printf 'EXIT=%s\n' "$_rc" >> "$_out"
        comm -13 "$_before" "$_after" > "$DOCKER_DIFF/$_ctr"
        exit 0 ;;
    commit)
        # 照这一层跑出来的增量，打一份 docker save 形状的 tar（顶层 blob = 这一层）
        _ctr=$2; _ref=$3
        _d="$DOCKER_FIX/$(printf '%s' "$_ref" | tr '/:' '__')"
        mkdir -p "$_d/root" "$_d/blobs/sha256"
        ( cd "$WTOOL_TEST_ROOT" && tar -cf "$_d/root/diff.tar" -T "$DOCKER_DIFF/$_ctr" )
        gzip -c "$_d/root/diff.tar" > "$_d/layer.tgz"
        _sha=$(sha256sum "$_d/layer.tgz" | cut -d' ' -f1)
        cp "$_d/layer.tgz" "$_d/blobs/sha256/$_sha"
        printf '{"imageLayoutVersion":"1.0.0"}\n' > "$_d/oci-layout"
        printf '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:%s","size":10,"annotations":{"org.opencontainers.image.ref.name":"%s"}}]}\n' \
            "m$(printf '%s' "$_ref" | tr '/:' '__')" "$_ref" > "$_d/index.json"
        printf '{"schemaVersion":2,"layers":[{"digest":"sha256:%s"}]}\n' "$_sha" \
            > "$_d/blobs/sha256/m$(printf '%s' "$_ref" | tr '/:' '__')"
        ( cd "$_d" && tar -cf "$_d/oci.tar" oci-layout index.json blobs )
        printf '%s\n' "$_ref" >> "$DOCKER_IMAGES"
        exit 0 ;;
    save)
        # save <镜像> → 往 **stdout** 吐 commit 时为它准备的那份（引擎是 `docker save | tar -x`）
        cat "$DOCKER_FIX/$(printf '%s' "$2" | tr '/:' '__')/oci.tar"
        exit 0 ;;
    rm) : > "$DOCKER_PS"; exit 0 ;;
esac
exit 0
DEOF
chmod +x "$T/bin/docker"
PATH="$T/bin:$PATH"; export PATH
export DOCKER_LOG="$T/docker.log" DOCKER_IMAGES="$T/images.txt" DOCKER_PS="$T/ps.txt"
export DOCKER_FIX="$T/fix" DOCKER_DIFF="$T/diff" DOCKER_PROJ="$P" DOCKER_TAR="$T/save.tar"
export WTOOL_TEST_SLOW="${WTOOL_TEST_SLOW:-}"
export LOG_DIR="$T/state/editor_demo/build-logs/ubuntu_24.04" DOCKER_TIMELINE="$T/timeline.tsv"
# 桩是子进程，只认导出的变量 —— $T 是测试里的局部变量，桩里读不到（踩过：路径变成 /fake…）
export DOCKER_TMP="$T"
export WTOOL_TEST_ROOT="$T/fakeroot"
: > "$DOCKER_LOG"; : > "$DOCKER_IMAGES"; : > "$DOCKER_PS"

echo "== 1. 计划：planner 只算不写 =="
chk "docker-targets 读 build/targets.tsv" \
    "$(python3 "$PY" docker-targets "$P")" "ubuntu_24.04	base:24.04"
chk "docker-plan 按依赖排序 + 替换 {target}" \
    "$(python3 "$PY" docker-plan "$P" --target=ubuntu_24.04 | cut -f1 | paste -sd' ' -)" \
    "one two three other empty"
chk "父层给的是**镜像引用**（引擎要拿它起容器）" \
    "$(python3 "$PY" docker-plan "$P" --target=ubuntu_24.04 | awk -F'\t' '$1=="two"{print $2}')" \
    "demo/one:ubuntu_24.04"
chk "命令里的 {target} 被替换" \
    "$(python3 "$PY" docker-plan "$P" --target=ubuntu_24.04 | awk -F'\t' '$1=="two"{print $4}')" \
    "sh /proj/scripts/layer.sh two ubuntu_24.04"
python3 "$PY" docker-plan "$P" --target=nope >/dev/null 2>&1 && bad "没声明的目标居然过了" \
    || ok "没声明的目标被拒"

echo "== 2. build：起容器 → commit → __layer/ → __output/ =="
# --jobs=1：`/wtool-layer/layer.json` 是**每层各写一份、最后一份在最上面**，
# 并行跑时"谁是最后一个"不确定（实测这条断言会随机红）。并行本身由第 2c 节专门量。
"$WT" build editor/demo --jobs=1 > "$T/build1.log" 2>&1 || bad "build（引擎驱动 docker）" "$(cat "$T/build1.log")"
chk "四层都 commit 了（占位层不起容器）" \
    "$(tr '\n' ' ' < "$DOCKER_IMAGES" | sed 's/ $//')" \
    "demo/one:ubuntu_24.04 demo/two:ubuntu_24.04 demo/three:ubuntu_24.04 demo/other:ubuntu_24.04"
chk "★每层 payload 里只有自己那层的文件" \
    "$(for l in one two three other; do
         [ -f "$P/__output/ubuntu_24.04/$l/payload/usr/share/$l/file.txt" ] && printf '%s ' "$l"
       done | sed 's/ $//')" "one two three other"
chk "★两层不会叠在 one 的 payload 里（是增量）" \
    "$(ls "$P/__output/ubuntu_24.04/one/payload/usr/share/" 2>/dev/null | grep -v '^one$' || true)" ""
chk "__layer/<target>/ 里有 4 个条目" \
    "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["manifests"]))' \
       "$P/__layer/ubuntu_24.04/index.json")" "4"
chk "OWNED.tsv 记的层名是这一层自己" \
    "$(awk -F'\t' 'END{print $3}' "$P/__output/ubuntu_24.04/one/OWNED.tsv")" "one"
chk "★build/export.filter 生效（*.log 没进 payload）" \
    "$(find "$P/__output/ubuntu_24.04/one/payload" -name '*.log' | wc -l | tr -d ' ')" "0"
chk "白障（.wh.）不落进 payload" \
    "$(find "$P/__output/ubuntu_24.04" -name '.wh.*' | wc -l | tr -d ' ')" "0"
[ -f "$P/__output/ubuntu_24.04/empty/OWNED.tsv" ] && ok "占位层留了一个空的 output 层" \
    || bad "占位层没有 output 层"
grep -q '^run -d' "$DOCKER_LOG" && ok "真的起了容器（docker run -d）" || bad "没起容器"
grep -q -- '--network=host' "$DOCKER_LOG" && ok "容器用 host 网络（代理要它）" || bad "没加 --network=host"
grep -q ':/proj:ro' "$DOCKER_LOG" && ok "项目只读挂进 /proj" || bad "没挂 /proj"

echo "== 2b. 输入指纹（进镜像）+ 产出事实（跟着层走）（ADR-026 §4）=="
chk "镜像里有 /wtool-layer/layer.json（从 registry 拉回来能自述来历）" "yes" \
    "$([ -f "$WTOOL_TEST_ROOT/wtool-layer/layer.json" ] && echo yes || echo no)"
# 每层都往 /wtool-layer/ 写自己那份，最后一层写在最上面 —— 所以看到的是最后一层的
chk "它记的是最后一层（每层各写各的，最后那份在最上面）" "other" \
    "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["layer"])' \
       "$WTOOL_TEST_ROOT/wtool-layer/layer.json")"
chk "基镜像记的是 digest，不只记 tag" "yes" \
    "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))["inputs"]
print("yes" if d.get("base_digest") else "no")' "$WTOOL_TEST_ROOT/wtool-layer/layer.json")"
chk "★它不落进 payload（导出只取 root/.wtool/*）" "0" \
    "$(find "$P/__output/ubuntu_24.04" -name 'layer.json' | wc -l | tr -d ' ')"
chk "产出事实跟着层走：__layer/<target>/<层>.json" "yes" \
    "$([ -f "$P/__layer/ubuntu_24.04/one.json" ] && echo yes || echo no)"
chk "产出事实里有 payload 的 sha256（OWNED.tsv 的 sha256，覆盖每个文件的内容）" "64" \
    "$(python3 -c 'import json,sys
print(len(json.load(open(sys.argv[1]))["produced"]["payload_sha256"]))' \
       "$P/__layer/ubuntu_24.04/one.json")"
chk "产出事实里有文件数（>0）" "yes" \
    "$(python3 -c 'import json,sys
print("yes" if json.load(open(sys.argv[1]))["produced"]["payload_files"] > 0 else "no")' \
       "$P/__layer/ubuntu_24.04/one.json")"
# 事实文件就放在布局目录里（实测 `docker load` **容忍**多出来的文件，见 journal 第 10 轮）；
# 而 `layer-load` / `push-layer` 是 `tar -c -C 布局 . | docker load`，所以要确认它真在 tar 里
chk "事实文件和布局在同一个目录里" "yes" \
    "$([ -f "$P/__layer/ubuntu_24.04/one.json" ] && [ -f "$P/__layer/ubuntu_24.04/index.json" ] \
       && echo yes || echo no)"
_tar_probe=$(mktemp)
tar -c -C "$P/__layer/ubuntu_24.04" . > "$_tar_probe"
chk "喂给 docker load 的 tar 里带着它（多出来的文件 docker 会忽略）" "yes" \
    "$(tar -tf "$_tar_probe" | grep -qx './one.json' && echo yes || echo no)"
rm -f "$_tar_probe"

echo "== 2c. 并行：父层就绪的兄弟层同时跑（BL-34）=="
#   three 和 other 都挂在 two 下面 —— 它们应该**重叠**跑，而不是一个接一个。
#   量法：桩把每层的 start/end 记进时间线，看有没有交叠（有层在跑时又开了新层）。
: > "$DOCKER_TIMELINE"
rm -rf "$P/__output/ubuntu_24.04" "$P/__layer"
: > "$DOCKER_IMAGES"
# 假根也要清：镜像都没了 = 下一轮容器从基础镜像新起，之前那些文件本来就不该在
# （不清的话层脚本写的文件"早就有了"，桩算出来的增量是空的 —— 实测四层 blob 全 54 字节）
rm -rf "$WTOOL_TEST_ROOT"; mkdir -p "$WTOOL_TEST_ROOT"
WTOOL_TEST_SLOW=1 "$WT" build editor/demo --jobs=2 > "$T/par.log" 2>&1 \
    || bad "并行 build" "$(cat "$T/par.log")"
_overlap=$(python3 - "$DOCKER_TIMELINE" <<'PYOV'
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
open_layers, seen = set(), False
for ev, layer in rows:
    if ev == "start":
        if open_layers:
            seen = True
        open_layers.add(layer)
    else:
        open_layers.discard(layer)
print("yes" if seen else "no")
PYOV
)
chk "★兄弟层真的重叠跑了（父层就绪就同时开）" "$_overlap" "yes"
grep -q '开跑' "$T/par.log" && ok "打了『开跑 X（并行 n/N）』" || bad "没有并行日志" "$(head -6 "$T/par.log")"

echo "== 3. 续跑：什么都不用重做 =="
: > "$DOCKER_LOG"
"$WT" build editor/demo > "$T/build2.log" 2>&1 || bad "第二次 build" "$(cat "$T/build2.log")"
chk "★第二次一次容器都没起" "$(grep -c '^run -d' "$DOCKER_LOG" || true)" "0"
chk "★也没有再 docker save（layout 里已经有了）" "$(grep -c '^save ' "$DOCKER_LOG" || true)" "0"
grep -q '跳过' "$T/build2.log" && ok "说了跳过（✓ X（docker 里已有，跳过））" \
    || bad "没说跳过" "$(cat "$T/build2.log")"

echo "== 4. 删掉 docker 里的镜像 → 从 __layer/ 装回来接着走 =="
: > "$DOCKER_IMAGES"; : > "$DOCKER_LOG"         # docker 存储被 prune 了
rm -rf "$P/__output/ubuntu_24.04/other"           # 顺手让最后一层需要重新导出
"$WT" build editor/demo > "$T/build3.log" 2>&1 || bad "docker 里没镜像时 build" "$(cat "$T/build3.log")"
grep -q '从 __layer/ 恢复' "$T/build3.log" \
    && ok "镜像不在 docker 里 → 从 __layer/ 装回来" || bad "没走 __layer/ 恢复那条路" "$(cat "$T/build3.log")"
grep -q '^load' "$DOCKER_LOG" && ok "用的是 docker load（tar 当管道）" || bad "没调 docker load" "$(cat "$DOCKER_LOG")"
[ -f "$P/__output/ubuntu_24.04/other/payload/usr/share/other/file.txt" ] \
    && ok "缺的那层重新导出了" || bad "缺的那层没补回来"

echo "== 5. 容器里失败：这一层不出、退出码非 0、日志贴出来 =="
: > "$DOCKER_IMAGES"; : > "$DOCKER_LOG"
rm -rf "$P/__output/ubuntu_24.04" "$P/__layer"
printf '#!/bin/sh\necho boom >&2\nexit 3\n' > "$P/scripts/layer.sh"
_rc=0
"$WT" build editor/demo > "$T/build4.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "失败时退出码非 0" || bad "失败了还报成功"
grep -q 'boom' "$T/build4.log" && ok "把容器里的日志尾部贴出来了" || bad "没贴日志" "$(tail -5 "$T/build4.log")"
[ -d "$P/__output/ubuntu_24.04/one" ] && bad "失败了还留了半成品 output 层" || ok "失败时没有留下半成品"
grep -q '^commit ' "$DOCKER_LOG" && bad "失败了居然 commit 了" || ok "失败时不 commit"
# 换回能跑的 layer.sh：上面那个"必失败"的脚本是为了这一节，别留给后面的节
cat > "$P/scripts/layer.sh" <<'EOF'
#!/bin/sh
set -e
L=$1
D="$WTOOL_TEST_ROOT/root/.wtool/usr/share/$L"
mkdir -p "$D"
printf '%s\n' "$L" > "$D/file.txt"
printf 'junk\n' > "$D/skip.log"
: > "$D/.wh.deleted"
EOF
chmod +x "$P/scripts/layer.sh"

echo "== 6. --dry-run：一个字节都不动 =="
: > "$DOCKER_LOG"; : > "$DOCKER_IMAGES"
rm -rf "$P/__output" "$P/__layer" "$WTOOL_STATE"
"$WT" build editor/demo --dry-run > "$T/dry.log" 2>&1 || bad "dry-run" "$(cat "$T/dry.log")"
chk "dry-run 不碰 docker" "$(grep -c '^run \|^commit \|^save ' "$DOCKER_LOG" || true)" "0"
[ -d "$P/__output" ] && bad "dry-run 建了 __output/" || ok "dry-run 不建 __output/"
[ -d "$P/__layer" ] && bad "dry-run 建了 __layer/" || ok "dry-run 不建 __layer/"
grep -q 'dry-run' "$T/dry.log" && ok "dry-run 打了计划" || bad "dry-run 没打计划"
# dry-run 的收尾语不能说"就绪"：那时候 __layer/ 和 __output/ 里**可能什么都没有**
grep -q '个目标就绪' "$T/dry.log" && bad "dry-run 说了『N 个目标就绪』（那时候什么都没写）" \
    || ok "★dry-run 不说『就绪』"
grep -q '什么都没执行' "$T/dry.log" && ok "★dry-run 的收尾语说清了『什么都没执行』" \
    || bad "dry-run 收尾语不对" "$(tail -2 "$T/dry.log")"

echo "== 7. 清单写错时的说法 =="
cp "$P/build/layers.tsv" "$T/layers.bak"
rm -f "$P/build/layers.tsv"
_rc=0
"$WT" build editor/demo > "$T/nolayers.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "没有层清单时 build 拒绝（也没有 build.sh 可退）" || bad "居然成功了"
grep -q 'build/layers.tsv' "$T/nolayers.log" && grep -q 'ADR-0029' "$T/nolayers.log" \
    && ok "说清了缺什么、指向哪条 ADR" || bad "没说清" "$(cat "$T/nolayers.log")"
printf 'x\t-\tdemo/x\tsh /proj/x.sh\nx\t-\tdemo/y\tsh /proj/y.sh\n' > "$P/build/layers.tsv"
_rc=0
"$WT" build editor/demo > "$T/duplayer.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && grep -q '重复' "$T/duplayer.log" && ok "层名重复被拒" || bad "重复层名没拒" "$(cat "$T/duplayer.log")"
cp "$T/layers.bak" "$P/build/layers.tsv"

echo "== 8. 产物账本：引擎驱动构建要把来源记下来（ADR-0036）=="
# 这条路里**没有项目脚本**（起容器/commit/导出都是引擎干的），所以"这批产物是本机编的"
# 只能由引擎记 —— 项目自己的 build.sh 够不着。读它的是 wtool_plan.py 的 project_state()。
AF="$WTOOL_STATE/editor/demo/artifacts.tsv"
: > "$DOCKER_LOG"; : > "$DOCKER_IMAGES"
rm -rf "$P/__output" "$P/__layer" "$WTOOL_STATE"
"$WT" build editor/demo > "$T/art1.log" 2>&1 || bad "为账本重跑一次 build" "$(cat "$T/art1.log")"
[ -f "$AF" ] && ok "引擎驱动构建写了账本 \$WTOOL_STATE/editor/demo/artifacts.tsv" \
    || bad "引擎驱动构建没写账本（ADR-0036 的那条路）"
chk "账本每行 4 列（TAB 分隔：kind/路径/来源/时间）" \
    "$(awk -F'\t' 'NF != 4 {n++} END {print n+0}' "$AF")" "0"
chk "来源列全是 build:<target>" "$(cut -f3 "$AF" | sort -u | paste -sd, -)" "build:ubuntu_24.04"
chk "一行一个层目录（相对项目根，含占位层 empty）" "$(cut -f2 "$AF" | sort | paste -sd, -)" \
    "__output/ubuntu_24.04/empty,__output/ubuntu_24.04/one,__output/ubuntu_24.04/other,__output/ubuntu_24.04/three,__output/ubuntu_24.04/two"
# 幂等：再构建一次是**截断重写**，不是追加（同一路径不许写两遍把表撑爆）
cp "$AF" "$T/art.first"
"$WT" build editor/demo > "$T/art2.log" 2>&1 || bad "第二次 build（账本幂等）" "$(cat "$T/art2.log")"
chk "再 build 一次：行数不变（不堆积）" "$(wc -l < "$AF" | tr -d ' ')" "$(wc -l < "$T/art.first" | tr -d ' ')"
chk "再 build 一次：kind/路径/来源逐字节相同（截断重写）" \
    "$(cut -f1-3 "$AF" | paste -sd';' -)" "$(cut -f1-3 "$T/art.first" | paste -sd';' -)"
# dry-run：一个字节都不写（连账本也不写）
rm -f "$AF"
"$WT" build editor/demo --dry-run > "$T/artdry.log" 2>&1 || bad "dry-run（账本）" "$(cat "$T/artdry.log")"
[ -e "$AF" ] && bad "dry-run 写了账本" || ok "dry-run 不写账本"
# 读法：「下gz包」那格只认**裸** `download`；build:* / 别的值 / 没有账本都是「可执行」
# （⚠️ 精确相等，不是前缀 —— 退休的 download.sh 写的 `download:$TAG` 对不上，见 ADR-0036）
printf '{}\n' > "$P/scripts/release.json"
_cell() { env -u WTOOL_ROOT python3 "$PY" table --root "$WTOOL_ROOT" --state "$WTOOL_STATE" 2>/dev/null \
          | sed 's/│/|/g' | grep -E '^\| editor/demo ' | awk -F'|' '{gsub(/^ +| +$/,"",$11); print $11}'; }
"$WT" build editor/demo > "$T/art3.log" 2>&1 || bad "第三次 build（账本读法）" "$(cat "$T/art3.log")"
chk "账本来源 build:* → 下gz包=可执行（本机自己编的）" "$(_cell)" "可执行"
printf 'payload\t__output/ubuntu_24.04/one\tdownload\t2026-10-04T00:00:00+0800\n' > "$AF"
chk "账本来源裸 download → 下gz包=已完成（下载解的）" "$(_cell)" "已完成"
printf 'payload\t__output/ubuntu_24.04/one\tdownload:v1\t2026-10-04T00:00:00+0800\n' > "$AF"
chk "账本来源 download:<tag> 对不上（历史格式的坑）→ 可执行" "$(_cell)" "可执行"
rm -f "$AF"
chk "没有账本（今天下载侧就是这样）→ 下gz包=可执行" "$(_cell)" "可执行"

echo "== 9. 账本按项目分开：一次 build 两条路各写各的（ADR-0036）=="
# 一个**没有层清单**的项目 → cmd_build 回退到 scripts/build.sh（项目自驱那条路），
# 账本由脚本自己写。顺带断言引擎**真的把 $WTOOL_ARTIFACTS 喂进脚本**（空了就 exit 9）。
P2="$WTOOL_ROOT/editor/plain"
mkdir -p "$P2/scripts"
cat > "$P2/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="51"/>
EOF
cat > "$P2/scripts/build.sh" <<'EOF'
#!/bin/sh
set -eu
[ -n "${WTOOL_ARTIFACTS:-}" ] || { echo "引擎没喂 WTOOL_ARTIFACTS" >&2; exit 9; }
mkdir -p __output/main
: > __output/main/x
: > "$WTOOL_ARTIFACTS"
printf 'payload\t__output/main\tbuild:plain\t2026-10-04T00:00:00+0800\n' >> "$WTOOL_ARTIFACTS"
EOF
chmod +x "$P2/scripts/build.sh"
AP="$WTOOL_STATE/editor/plain/artifacts.tsv"
rm -f "$AF" "$AP"
# ⚠️ 这里**不能**写 `build all`：`wt_all_projects build` 只认"有 scripts/build.sh"的项目，
#    而 editor/demo 是纯引擎驱动（没有 build.sh）→ 会被 all 漏掉（见 BACKLOG BL-50）。
#    显式点名两个项目，一次调用里两条路都跑。
"$WT" build editor/demo editor/plain > "$T/all.log" 2>&1 || bad "一次 build 两条路（引擎驱动 + 项目自驱）" "$(cat "$T/all.log")"
[ -s "$AF" ] && ok "引擎驱动那条路（editor/demo）写了账本" \
    || bad "引擎驱动那条路没写账本" "$(cat "$T/all.log")"
[ -s "$AP" ] && ok "项目脚本那条路（editor/plain）写了账本 —— 引擎真喂了 \$WTOOL_ARTIFACTS" \
    || bad "项目脚本那条路没写成账本" "$(cat "$T/all.log")"
chk "按项目 id 分开：两份账本各自来源正确（谁也不覆盖谁）" \
    "$(cut -f3 "$AF" | sort -u | paste -sd, -)|$(cut -f3 "$AP")" \
    "build:ubuntu_24.04|build:plain"

echo "== 10. --rebuild：无视三条跳过判据，强制重编（A1）=="
#   三条跳过判据各自独立，全都得绕过：
#     ① docker 里已经有这个镜像  ② __layer/<target>/ 里有这一层  ③ __output/ 里有 OWNED.tsv
#   前置状态正好是"三样都齐、什么都不用重做"（第 8/9 节刚编过）。
: > "$DOCKER_LOG"
"$WT" build editor/demo --target=ubuntu_24.04 --rebuild > "$T/rb1.log" 2>&1 \
    || bad "--rebuild 重编" "$(cat "$T/rb1.log")"
chk "★① 镜像在 docker 里也重起容器（4 个非占位层）" "4" \
    "$(grep -c '^run -d' "$DOCKER_LOG" || true)"
chk "★② __layer/ 里已有这一层也重存（4 次 docker save）" "4" \
    "$(grep -c '^save ' "$DOCKER_LOG" || true)"
# ①③ 的提示打在**那一层自己的日志**里：wt_docker_layer 在后台子 shell 里跑
# （并行调度），输出进 <state>/<项目>/build-logs/<target>/<层>.wtool.log，不进主日志。
grep -q '无视 docker 里已有的镜像' "$LOG_DIR"/*.wtool.log && ok "说了它在无视①" || bad "没提①"
grep -q '无视 __output/ 里的旧产物' "$LOG_DIR"/*.wtool.log && ok "说了它在无视③" || bad "没提③"
# ③ 旧产物是**换掉**不是叠在上面：塞一个标记文件，重导之后它必须没了
: > "$P/__output/ubuntu_24.04/one/STALE-MARKER"
"$WT" build editor/demo --target=ubuntu_24.04 --rebuild > "$T/rb2.log" 2>&1 \
    || bad "第二次 --rebuild" "$(cat "$T/rb2.log")"
[ -e "$P/__output/ubuntu_24.04/one/STALE-MARKER" ] && bad "旧产物还在（叠上去了）" \
    || ok "★③ 旧产物被换掉（重导真的重来一遍）"
# __layer/ 里同一个层名只能有一个条目 —— 重建之后不能变成两个
chk "★重存之后 layout 里的条目数不变（没堆出重复的）" "4" \
    "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print(len(d["manifests"]))' "$P/__layer/ubuntu_24.04/index.json")"
chk "★层名不重复（重建 = 换掉旧条目，不是并排留着）" "0" \
    "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
names=[(m.get("annotations") or {}).get("io.wtool.layer") for m in d["manifests"]]
print(sum(1 for n in set(names) if names.count(n) > 1))' "$P/__layer/ubuntu_24.04/index.json")"
# 三条判据各自独立：只缺 __output/ 时，不带 --rebuild 只补导出、不重编
rm -rf "$P/__output/ubuntu_24.04/one"
: > "$DOCKER_LOG"
"$WT" build editor/demo --target=ubuntu_24.04 > "$T/rb3.log" 2>&1 \
    || bad "缺一层 output 时续跑" "$(cat "$T/rb3.log")"
chk "不带 --rebuild：仍然复用镜像（一次容器都不起）" "0" \
    "$(grep -c '^run -d' "$DOCKER_LOG" || true)"
[ -f "$P/__output/ubuntu_24.04/one/OWNED.tsv" ] && ok "缺的那层按③补了导出" \
    || bad "缺的那层没补回来"
# 计划侧也要认这个 flag（不认 = argparse 报错 = 动作被静默丢弃）
chk "★计划侧 docker-plan --rebuild 认这个 flag（计划内容不变）" \
    "$(python3 "$PY" docker-plan "$P" --target=ubuntu_24.04 --rebuild | cut -f1 | paste -sd' ' -)" \
    "one two three other empty"
# dry-run --rebuild：一个字节都不写，但要说清"会重跑"
: > "$DOCKER_LOG"
"$WT" build editor/demo --target=ubuntu_24.04 --rebuild --dry-run > "$T/rbdry.log" 2>&1 \
    || bad "dry-run --rebuild" "$(cat "$T/rbdry.log")"
chk "dry-run --rebuild 不碰 docker" \
    "$(grep -c '^run \|^commit \|^save ' "$DOCKER_LOG" || true)" "0"
grep -q '重跑容器' "$T/rbdry.log" && ok "dry-run --rebuild 说了会重跑每一层" \
    || bad "dry-run 没说 --rebuild" "$(cat "$T/rbdry.log")"

echo "== 11. 代理与本地镜像目录（构建容器的环境）=="
#   容器里 127.0.0.1 是容器自己 → 代理只有 --network=host 时才指得到宿主（这台机器实测：
#   WSL mirrored + Clash fake-IP，不带代理的 git clone 会"连上但不传数据"，卡到超时）
# ⚠️ "代理 : …" / "本地镜像: …" 是 wt_docker_layer 打的，落在**那一层自己的日志**里
# （wtool.log），主日志里看不到 —— 断言要对着 $LOG_DIR/*.wtool.log。
# 宿主**没有**那个目录时不许挂（挂了 docker 会自己建一个空目录 = 假前提）——
# 用 WTOOL_MIRROR_DIR 指一个不存在的路径来量，别依赖开发机上 ~/self/mirror 在不在。
: > "$DOCKER_LOG"
WTOOL_MIRROR_DIR="$T/nope" "$WT" build editor/demo --target=ubuntu_24.04 --rebuild \
    > "$T/nomir.log" 2>&1 || bad "WTOOL_MIRROR_DIR 不存在时重编" "$(cat "$T/nomir.log")"
_runline=$(grep -m1 '^run -d' "$DOCKER_LOG")
case $_runline in *--network=host*) ok "★容器用 host 网络" ;; *) bad "没有 --network=host" ;; esac
case $_runline in *'-e HTTP_PROXY'*) ok "传了 HTTP_PROXY（宿主同名变量）" ;; *) bad "没传 HTTP_PROXY" ;; esac
case $_runline in *'-e HTTPS_PROXY'*) ok "传了 HTTPS_PROXY" ;; *) bad "没传 HTTPS_PROXY" ;; esac
case $_runline in *'-e NO_PROXY'*) ok "传了 NO_PROXY（不走代理的域名要能带进去）" ;; *) bad "没传 NO_PROXY" ;; esac
case $_runline in *'-e ALL_PROXY'*) ok "传了 ALL_PROXY" ;; *) bad "没传 ALL_PROXY" ;; esac
chk "宿主没有那个目录时不挂 /mirror" "0" \
    "$(printf '%s\n' "$_runline" | grep -c '/mirror:ro' || true)"
grep -q '本地镜像: 无' "$LOG_DIR"/*.wtool.log && ok "日志说了没挂本地镜像" \
    || bad "日志没说不挂" "$(grep -m2 '本地镜像' "$LOG_DIR"/*.wtool.log)"
grep -q '代理 : ' "$LOG_DIR"/*.wtool.log && ok "日志说了这次构建用的代理" \
    || bad "日志没说代理" "$(grep -m2 '代理' "$LOG_DIR"/*.wtool.log)"
mkdir -p "$T/mirror/github"
: > "$DOCKER_LOG"
WTOOL_MIRROR_DIR="$T/mirror" "$WT" build editor/demo --target=ubuntu_24.04 --rebuild \
    > "$T/mir.log" 2>&1 || bad "带 WTOOL_MIRROR_DIR 重编" "$(cat "$T/mir.log")"
_mirline=$(grep -m1 '^run -d' "$DOCKER_LOG")
case $_mirline in *"-v $T/mirror:/mirror:ro"*) ok "★本地镜像目录只读挂进 /mirror" ;;
    *) bad "没有挂 /mirror" "$_mirline" ;; esac
grep -q "本地镜像: $T/mirror → /mirror:ro" "$LOG_DIR"/*.wtool.log && ok "日志里说了挂了什么" \
    || bad "日志没说本地镜像" "$(grep -m2 '本地镜像' "$LOG_DIR"/*.wtool.log)"


echo "== 12. B1：导出被拒的层，不许被下一轮当成『已经导出好了』 =="
#   假成功 bug 的形状：失败的那一轮在 __output/<t>/<层>/ 里留下了 OWNED.tsv →
#   下一次 wtool build 的跳过判据 ③ 命中 → **静默 rc=0**（还往账本记一行背书）。
#   这里用一层真的会产出"指向包外的软链"来量（wt_owned_scan 拒收它）。
cat > "$P/scripts/esc.sh" <<'EOF'
#!/bin/sh
set -e
D="$WTOOL_TEST_ROOT/root/.wtool/usr/share/esc"
mkdir -p "$D"
printf 'x\n' > "$D/file.txt"
ln -sf /etc/hostname "$D/escape"     # 指向包外 → 这一层不能用
EOF
chmod +x "$P/scripts/esc.sh"
cp "$P/build/layers.tsv" "$T/layers.bak2"
printf 'esc\ttwo\tdemo/esc\tsh /proj/scripts/esc.sh\n' >> "$P/build/layers.tsv"
rm -rf "$P/__output/ubuntu_24.04/esc"
_rc=0
"$WT" build editor/demo --target=ubuntu_24.04 > "$T/b1a.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "指向包外的软链让 build 失败（rc≠0）" \
    || bad "居然报成功了（B1 的假成功）" "$(cat "$T/b1a.log")"
[ -e "$P/__output/ubuntu_24.04/esc" ] \
    && bad "被拒之后 __output/ 里留了残骸" \
    || ok "★被拒之后不留残骸（连 payload/ 都没有）"
grep -q '悬空' "$LOG_DIR/esc.wtool.log" && ok "说清了原因（换台机器必然悬空）" \
    || bad "没说原因" "$(tail -4 "$LOG_DIR/esc.wtool.log" 2>/dev/null)"
# 镜像已经 commit 进 __layer/ 了（这是"构建成功、导出失败"的正常形状）——
# 留着它下一轮只重试导出，不用重编（③ 才是这里的关键判据）
chk "这一层在 __layer/ 里有（commit 成功了，失败的是导出）" "esc" \
    "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print([(m.get("annotations") or {}).get("io.wtool.layer") for m in d["manifests"]
       if (m.get("annotations") or {}).get("io.wtool.layer")=="esc"][0])' \
       "$P/__layer/ubuntu_24.04/index.json" 2>/dev/null || echo "-")"
# ★ 重跑：必须还是失败 —— bug 的形状是这里变成 rc=0 并说"就绪"
_rc=0
"$WT" build editor/demo --target=ubuntu_24.04 > "$T/b1b.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "★重跑仍然失败（没有被当成已经导出好了）" \
    || bad "重跑报成功了（B1 的假成功：失败被当成已导出）" "$(cat "$T/b1b.log")"
[ -e "$P/__output/ubuntu_24.04/esc" ] && bad "重跑之后留了残骸" || ok "重跑也不留残骸"
grep -q '个目标就绪' "$T/b1b.log" && bad "重跑说了『就绪』（撒谎）" || ok "重跑不说『就绪』"
grep -q 'esc' "$AF" 2>/dev/null && bad "账本给失败的层记了一行背书" \
    || ok "账本没有给失败的层背书"
cp "$T/layers.bak2" "$P/build/layers.tsv"
rm -f "$P/scripts/esc.sh"


echo "== 13. 账本（B2）：一行一个层目录（lang/x 各一行）+ 失败路径也要重写 =="
#   ① 行粒度按 ADR-0036：`__output/<target>/<层目录>` 一行，层名可以带 `/`
#      （astronvim 的层就叫 `lang/lua`、`lang/python`…）—— 按目录深度遍历会把它们
#      压成一行 `lang`（那既不是一层，也让人以为只有一层语言层）。
#   ② 失败路径也要重写：不写的话账本停在上一次"全都好了"，替磁盘上已经没有的层背书。
cp "$P/build/layers.tsv" "$T/layers.bak3"
cat > "$P/scripts/ok.sh" <<'EOF'
#!/bin/sh
set -e
D="$WTOOL_TEST_ROOT/root/.wtool/usr/share/lang-ok"
mkdir -p "$D"
printf 'ok\n' > "$D/file.txt"
EOF
cat > "$P/scripts/bad.sh" <<'EOF'
#!/bin/sh
set -e
D="$WTOOL_TEST_ROOT/root/.wtool/usr/share/lang-bad"
mkdir -p "$D"
printf 'bad\n' > "$D/file.txt"
ln -sf /etc/hostname "$D/escape"     # 指向包外 → 这一层导出时被拒
EOF
chmod +x "$P/scripts/ok.sh" "$P/scripts/bad.sh"
printf 'lang/ok\ttwo\tdemo/lang-ok\tsh /proj/scripts/ok.sh\n' >> "$P/build/layers.tsv"
"$WT" build editor/demo --target=ubuntu_24.04 > "$T/b2a.log" 2>&1 \
    || bad "带嵌套层名（lang/ok）的 build" "$(cat "$T/b2a.log")"
chk "★lang/ok 自己一行（不是被压成 lang）" "1" \
    "$(awk -F'\t' '$2=="__output/ubuntu_24.04/lang/ok"' "$AF" | wc -l | tr -d ' ')"
chk "★没有 __output/ubuntu_24.04/lang 这种"中间目录"行" "0" \
    "$(awk -F'\t' '$2=="__output/ubuntu_24.04/lang"' "$AF" | wc -l | tr -d ' ')"
chk "六个层目录六行（含占位层 empty；来源都带 target）" "6|build:ubuntu_24.04" \
    "$(wc -l < "$AF" | tr -d ' ')|$(cut -f3 "$AF" | sort -u | paste -sd, -)"
# ② 失败路径：先往账本里塞一行"谎言"（磁盘上根本没有 lang/bad），再让这一轮失败 ——
#    重写之后谎言必须消失，而**确实在磁盘上**的那些层仍然要被记着。
printf 'payload\t__output/ubuntu_24.04/lang/bad\tbuild:ubuntu_24.04\t2026-10-04T00:00:00+0800\n' >> "$AF"
printf 'lang/bad\ttwo\tdemo/lang-bad\tsh /proj/scripts/bad.sh\n' >> "$P/build/layers.tsv"
_rc=0
"$WT" build editor/demo --target=ubuntu_24.04 > "$T/b2b.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "加了必失败的层之后这一轮按预期失败" || bad "这一轮居然成功了"
chk "★失败之后账本被重写过（塞进去的那行『谎言』没了）" "0" \
    "$(awk -F'\t' '$2=="__output/ubuntu_24.04/lang/bad"' "$AF" | wc -l | tr -d ' ')"
chk "★失败之后仍然如实记着磁盘上好着的层（lang/ok 还在）" "1" \
    "$(awk -F'\t' '$2=="__output/ubuntu_24.04/lang/ok"' "$AF" | wc -l | tr -d ' ')"
chk "失败之后行数还是 6（整表重写：不丢好层、不追加坏层）" "6" \
    "$(wc -l < "$AF" | tr -d ' ')"
[ -e "$P/__output/ubuntu_24.04/lang/bad" ] && bad "失败的那层留了残骸" \
    || ok "失败的那层没有残骸（B1 那条同一条路）"
cp "$T/layers.bak3" "$P/build/layers.tsv"
rm -f "$P/scripts/ok.sh" "$P/scripts/bad.sh"


# --------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'docker_build_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
