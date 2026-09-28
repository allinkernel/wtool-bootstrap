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
#   1. 引擎按 build/targets.tsv + build/layers.tsv 起容器、commit、落 layer/、导 output/
#   2. **一层镜像对一层 output**：每层 payload 里只有它自己那层的文件
#   3. 续跑：镜像在 docker 里就不重起容器；layout/output 齐了就不重复 save/导出
#   4. 父层不在 docker 里 → 从 layer/ 装回来（docker 存储只是缓存）
#   5. 容器里失败 → 这一层不出、不 commit、退出码非 0、日志尾部贴出来
#   6. 占位层（镜像名 -）留一个空的 output 层
#   7. build/export.filter 真的过滤掉了东西
#   8. --dry-run 一个字节不写
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
<wtool schema="1" id="editor/demo" priority="50"><build kind="docker"/></wtool>
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
        grep -qx -- "$3" "$DOCKER_IMAGES" 2>/dev/null && exit 0 || exit 1 ;;
    volume) exit 0 ;;
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
        # 容器里 `/proj` 是挂载点；桩在宿主机上，把它换成本机的项目目录
        sed "s|/proj|$DOCKER_PROJ|g" "$_run" > "$T_FAKE_RUN"
        ( cd "$WTOOL_TEST_ROOT" && find . \( -type f -o -type l \) 2>/dev/null |
              sed 's|^\./||' | LC_ALL=C sort ) > "$T_BEFORE"
        _rc=0
        WTOOL_TEST_ROOT="$WTOOL_TEST_ROOT" sh "$T_FAKE_RUN" >> "$_out" 2>&1 || _rc=$?
        ( cd "$WTOOL_TEST_ROOT" && find . \( -type f -o -type l \) 2>/dev/null |
              sed 's|^\./||' | LC_ALL=C sort ) > "$T_AFTER"
        printf 'EXIT=%s\n' "$_rc" >> "$_out"
        comm -13 "$T_BEFORE" "$T_AFTER" > "$DOCKER_DIFF/$_ctr"
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
export T_FAKE_RUN="$T/fake.run" T_BEFORE="$T/before.txt" T_AFTER="$T/after.txt"
export LOG_DIR="$T/state/editor_demo/build-logs/ubuntu_24.04"
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

echo "== 2. build：起容器 → commit → layer/ → output/ =="
"$WT" build editor/demo > "$T/build1.log" 2>&1 || bad "build（引擎驱动 docker）" "$(cat "$T/build1.log")"
chk "四层都 commit 了（占位层不起容器）" \
    "$(tr '\n' ' ' < "$DOCKER_IMAGES" | sed 's/ $//')" \
    "demo/one:ubuntu_24.04 demo/two:ubuntu_24.04 demo/three:ubuntu_24.04 demo/other:ubuntu_24.04"
chk "★每层 payload 里只有自己那层的文件" \
    "$(for l in one two three other; do
         [ -f "$P/output/ubuntu_24.04/$l/payload/usr/share/$l/file.txt" ] && printf '%s ' "$l"
       done | sed 's/ $//')" "one two three other"
chk "★两层不会叠在 one 的 payload 里（是增量）" \
    "$(ls "$P/output/ubuntu_24.04/one/payload/usr/share/" 2>/dev/null | grep -v '^one$' || true)" ""
chk "layer/<target>/ 里有 4 个条目" \
    "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["manifests"]))' \
       "$P/layer/ubuntu_24.04/index.json")" "4"
chk "OWNED.tsv 记的层名是这一层自己" \
    "$(awk -F'\t' 'END{print $3}' "$P/output/ubuntu_24.04/one/OWNED.tsv")" "one"
chk "★build/export.filter 生效（*.log 没进 payload）" \
    "$(find "$P/output/ubuntu_24.04/one/payload" -name '*.log' | wc -l | tr -d ' ')" "0"
chk "白障（.wh.）不落进 payload" \
    "$(find "$P/output/ubuntu_24.04" -name '.wh.*' | wc -l | tr -d ' ')" "0"
[ -f "$P/output/ubuntu_24.04/empty/OWNED.tsv" ] && ok "占位层留了一个空的 output 层" \
    || bad "占位层没有 output 层"
grep -q '^run -d' "$DOCKER_LOG" && ok "真的起了容器（docker run -d）" || bad "没起容器"
grep -q -- '--network=host' "$DOCKER_LOG" && ok "容器用 host 网络（代理要它）" || bad "没加 --network=host"
grep -q ':/proj:ro' "$DOCKER_LOG" && ok "项目只读挂进 /proj" || bad "没挂 /proj"

echo "== 3. 续跑：什么都不用重做 =="
: > "$DOCKER_LOG"
"$WT" build editor/demo > "$T/build2.log" 2>&1 || bad "第二次 build" "$(cat "$T/build2.log")"
chk "★第二次一次容器都没起" "$(grep -c '^run -d' "$DOCKER_LOG" || true)" "0"
chk "★也没有再 docker save（layout 里已经有了）" "$(grep -c '^save ' "$DOCKER_LOG" || true)" "0"
grep -q '跳过构建' "$T/build2.log" && ok "说了跳过构建" || bad "没说跳过" "$(cat "$T/build2.log")"

echo "== 4. 删掉 docker 里的镜像 → 从 layer/ 装回来接着走 =="
: > "$DOCKER_IMAGES"; : > "$DOCKER_LOG"         # docker 存储被 prune 了
rm -rf "$P/output/ubuntu_24.04/other"           # 顺手让最后一层需要重新导出
"$WT" build editor/demo > "$T/build3.log" 2>&1 || bad "docker 里没镜像时 build" "$(cat "$T/build3.log")"
grep -q 'layer/ubuntu_24.04/ 里有 → 装回来' "$T/build3.log" \
    && ok "父层不在 docker 里 → 从 layer/ 装回来" || bad "没走 layer/ 恢复那条路" "$(cat "$T/build3.log")"
grep -q '^load' "$DOCKER_LOG" && ok "用的是 docker load（tar 当管道）" || bad "没调 docker load" "$(cat "$DOCKER_LOG")"
[ -f "$P/output/ubuntu_24.04/other/payload/usr/share/other/file.txt" ] \
    && ok "缺的那层重新导出了" || bad "缺的那层没补回来"

echo "== 5. 容器里失败：这一层不出、退出码非 0、日志贴出来 =="
: > "$DOCKER_IMAGES"; : > "$DOCKER_LOG"
rm -rf "$P/output/ubuntu_24.04" "$P/layer"
printf '#!/bin/sh\necho boom >&2\nexit 3\n' > "$P/scripts/layer.sh"
_rc=0
"$WT" build editor/demo > "$T/build4.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "失败时退出码非 0" || bad "失败了还报成功"
grep -q 'boom' "$T/build4.log" && ok "把容器里的日志尾部贴出来了" || bad "没贴日志" "$(tail -5 "$T/build4.log")"
[ -d "$P/output/ubuntu_24.04/one" ] && bad "失败了还留了半成品 output 层" || ok "失败时没有留下半成品"
grep -q '^commit ' "$DOCKER_LOG" && bad "失败了居然 commit 了" || ok "失败时不 commit"

echo "== 6. --dry-run：一个字节都不动 =="
: > "$DOCKER_LOG"; : > "$DOCKER_IMAGES"
rm -rf "$P/output" "$P/layer" "$WTOOL_STATE"
"$WT" build editor/demo --dry-run > "$T/dry.log" 2>&1 || bad "dry-run" "$(cat "$T/dry.log")"
chk "dry-run 不碰 docker" "$(grep -c '^run \|^commit \|^save ' "$DOCKER_LOG" || true)" "0"
[ -d "$P/output" ] && bad "dry-run 建了 output/" || ok "dry-run 不建 output/"
[ -d "$P/layer" ] && bad "dry-run 建了 layer/" || ok "dry-run 不建 layer/"
grep -q 'dry-run' "$T/dry.log" && ok "dry-run 打了计划" || bad "dry-run 没打计划"

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

# --------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'docker_build_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
