#!/bin/sh
# docker_build_real.sh —— 引擎驱动构建的**真 docker** 冒烟测试（人工跑，不在 run_all.sh 里）
#
# 和 `docker_build_test.sh` 的分工：
#   docker_build_test.sh   打桩 docker：逻辑（排序/续跑/失败路径/契约文件）全覆盖，跑得快、不联网
#   本脚本                 **真 docker**：只走一遍"起容器 → 跑命令 → commit → 落 layer/ →
#                          导 output/"，用最小的镜像（alpine）验那条链路在真环境里通
#
# 为什么必须真跑一次：打桩测不出"真 docker 的脾气"——
#   `docker exec -d` 的缓冲、commit 抓不抓得到可写层、`docker save | tar -x` 的格式、
#   容器里写 /wtool-layer/ 的权限……这些只有真容器才现原形。
#
#   sh bootstrap/tests/docker_build_real.sh          # 默认用 alpine:latest
#   WT_REAL_IMAGE=ubuntu:24.04 sh .../docker_build_real.sh
#
# 它**只碰自己的东西**：一个临时工作区、一个 `wtool-smoke/one` 镜像、一个同名缓存卷，
# 跑完自己删掉（不动你已有的任何镜像/容器）。
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(dirname -- "$here")
WT="$boot/wtool.sh"
IMG=${WT_REAL_IMAGE:-alpine:latest}
TAG=wtool-smoke/one
TARGET=ubuntu_24.04

command -v docker >/dev/null 2>&1 || { echo "没有 docker，跳过（这个脚本要真 docker）"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; return 0; }
chk() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$3]  实际 [$2]"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-real.XXXXXX")
cleanup() {
    docker rm -f "wtool-build-one-$TARGET-$$" >/dev/null 2>&1 || true
    docker rmi -f "$TAG:$TARGET" >/dev/null 2>&1 || true
    docker volume rm "wtool-build-cache-demo-$TARGET" >/dev/null 2>&1 || true
    rm -rf -- "$T"
}
trap cleanup EXIT INT TERM

for _v in $(env | grep -o '^WTOOL_[A-Za-z_]*'); do unset "$_v"; done
export WTOOL_ROOT="$T/ws" WTOOL_STATE="$T/state" WTOOL_HOME="$T/home"
mkdir -p "$WTOOL_STATE" "$WTOOL_HOME"

P="$WTOOL_ROOT/demo"
mkdir -p "$P/build" "$P/scripts"
cat > "$P/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="demo" priority="50"><build kind="docker"/></wtool>
EOF
printf '%s\t%s\n' "$TARGET" "$IMG" > "$P/build/targets.tsv"
cat > "$P/build/layers.tsv" <<EOF
# 层名	父层	镜像名	容器里跑的命令
one	-	$TAG	sh /proj/scripts/one.sh
EOF
# 容器里跑的东西：往影子 $HOME（容器里是 root 的 $HOME，即 /root）里放文件
cat > "$P/scripts/one.sh" <<'EOF'
#!/bin/sh
set -e
mkdir -p "$HOME/.wtool/usr/share/wtool-smoke"
printf 'hello from a real container\n' > "$HOME/.wtool/usr/share/wtool-smoke/hello.txt"
printf 'junk\n' > "$HOME/.wtool/usr/share/wtool-smoke/skip.log"
EOF

echo "== 真 docker 走一遍（镜像 $IMG）=="
docker image inspect "$IMG" >/dev/null 2>&1 || docker pull "$IMG" >/dev/null
_rc=0
"$WT" build demo --target="$TARGET" > "$T/real.log" 2>&1 || _rc=$?
chk "wtool build 退出码 0" "$_rc" "0"
[ "$_rc" = 0 ] || sed 's/^/      /' "$T/real.log"

chk "镜像 commit 出来了" "yes" \
    "$(docker image inspect "$TAG:$TARGET" >/dev/null 2>&1 && echo yes || echo no)"
chk "层进了 layer/$TARGET/（OCI 布局）" "yes" \
    "$([ -f "$P/layer/$TARGET/index.json" ] && echo yes || echo no)"
chk "payload 里是这一层装的东西" "hello from a real container" \
    "$(cat "$P/output/$TARGET/one/payload/usr/share/wtool-smoke/hello.txt" 2>/dev/null || echo 缺失)"
chk "OWNED.tsv 扫了出来（层名对）" "one" \
    "$(awk -F'\t' 'END{print $3}' "$P/output/$TARGET/one/OWNED.tsv" 2>/dev/null || echo 缺失)"
chk "输入指纹在**镜像里**（从 registry 拉回来能自述来历）" "one" \
    "$(docker run --rm --entrypoint sh "$TAG:$TARGET" -c 'cat /wtool-layer/layer.json' 2>/dev/null \
       | python3 -c 'import json,sys;print(json.load(sys.stdin)["layer"])' 2>/dev/null || echo 缺失)"
chk "产出事实跟着层走" "yes" \
    "$([ -f "$P/layer/$TARGET/one.json" ] && echo yes || echo no)"

echo "== 续跑：第二次不该再起容器 =="
_ctr_before=$(docker ps -a --format '{{.Names}}' | grep -c '^wtool-build-' || true)
"$WT" build demo --target="$TARGET" > "$T/real2.log" 2>&1 || bad "第二次 build" "$(cat "$T/real2.log")"
# 引擎在多了一层调度之后，把"到底编了没有"写进**每一层自己的日志**，
# 顶层只印 `✓ <层>（docker 里已有，跳过）`
grep -q '跳过' "$T/real2.log" && ok "第二次说了跳过（✓ 层（docker 里已有，跳过））" \
    || bad "第二次没跳过" "$(tail -5 "$T/real2.log")"
_ctr_after=$(docker ps -a --format '{{.Names}}' | grep -c '^wtool-build-' || true)
chk "没留下容器" "$_ctr_before" "$_ctr_after"

echo "== 删掉 docker 里的镜像 → 从 layer/ 装回来 =="
docker rmi -f "$TAG:$TARGET" >/dev/null 2>&1 || true
rm -rf "$P/output/$TARGET/one"
"$WT" build demo --target="$TARGET" > "$T/real3.log" 2>&1 || bad "从 layer/ 恢复" "$(cat "$T/real3.log")"
grep -q '从 layer/ 恢复' "$T/real3.log" && ok "从 layer/ 装回来了" \
    || bad "没走恢复" "$(tail -5 "$T/real3.log")"
chk "payload 又回来了" "hello from a real container" \
    "$(cat "$P/output/$TARGET/one/payload/usr/share/wtool-smoke/hello.txt" 2>/dev/null || echo 缺失)"

printf '\n----------------------------------------\n'
printf 'docker_build_real: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
