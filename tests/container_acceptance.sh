#!/bin/sh
# container_acceptance.sh —— **人工跑的容器总验收**（不在 run_all.sh 里）
#
# 它不是一个独立脚本，而是**喂给容器里那个交互 shell 的一串命令**：
#   container-raw.sh 最后 `exec bash -i`，而 `-i` 的 bash 会从 stdin 读命令 ——
#   于是宿主机这样起，容器里就按这份脚本从零走一遍：
#
#   docker run -i --rm --network=host -v ~/self/wtool:/wtool \
#     -v wtool-apt-cache:/var/cache/apt ubuntu:24.04 \
#     bash -c 'bash /wtool/bootstrap/scripts/container-raw.sh' \
#     < bootstrap/tests/container_acceptance.sh
#
# 为什么这么绕：`container-raw.sh` 刻意什么都不装（等价于"刚 repo sync 完"），
# 总验收要验的正是"这台什么都没有的机器上，用户按文档敲一遍能不能走通"。
# 用 `container-shell.sh` 测会把要验证的前提条件提前满足掉。
#
# 验的是**用户的视角**，不是内部实现：
#   0  基线：python3 / git / wtool 一个都没有
#   1  ./install.sh（四步，只装 wtool 自己）
#   2  `eval "$(wtool doctor --quiet)"` 之后 wtool 真的能用
#   3  pack-release →（file:// 当发布页）→ download-release → unpack-release → 表格/validate
#      旧命令名 die + 指路 / install-uninstall 完全配对 / 没有 docker 时的拒绝与指路
#   4  真工作区里的项目（astronvim_v5）说不说实话
#   5  系统层：sudo-install（系统文件 + task + marker 幂等 + sudo-uninstall）与
#      "install.sh 已经换过源 → 系统层跳过"（ADR-0032；这一段 2026-10-04 补，
#       以前没验过，换源重复和进度缺失两个 bug 就是这么漏掉的）
#
# ⚠️ 它**不碰宿主的 $HOME**：容器里 WTOOL_HOME 指向 /tmp 下的临时目录，
#    最后 `rm -rf` 收走。宿主工作区只被 install.sh 第 2 步刷新那几条根目录软链。
set -e
say() { printf '\n\033[1;36m###### %s\033[0m\n' "$*"; }

say "0. 容器基线（应该是'什么都没装'）"
printf 'python3: %s\n' "$(command -v python3 || echo 没有)"
printf 'git    : %s\n' "$(command -v git || echo 没有)"
printf 'wtool  : %s\n' "$(command -v wtool || echo 没有)"

say "1. install.sh —— 准备环境 + 装 wtool 自己（四步，做完就停）"
cd /wtool && ./install.sh

say "2. 让当前 shell 认识 wtool（照 README 的 eval 那条路），再看现状"
eval "$(sh "$HOME/.wtool/bootstrap/wtool.sh" doctor --quiet)" || true
printf 'wtool  : %s\n' "$(command -v wtool || echo 还是没有)"
command -v wtool >/dev/null || { echo "❌ install.sh 装完了却敲不到 wtool"; exit 1; }
wtool version
wtool | head -20 || true

say "3. 造一个本地项目，走完整条流水线（不联网）"
W=$(mktemp -d); mkdir -p "$W/ws/terminal/demo/scripts" "$W/ws/terminal/demo/output/ubuntu_24.04/main/payload/usr/bin" "$W/h" "$W/st"
P="$W/ws/terminal/demo"
printf '#!/bin/sh\ntrue\n' > "$P/scripts/build.sh"
printf 'hello\n' > "$P/output/ubuntu_24.04/main/payload/usr/bin/demo"; chmod +x "$P/output/ubuntu_24.04/main/payload/usr/bin/demo"
printf 'demo=1\n' > "$P/demo.conf"
cat > "$P/wtool.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="terminal/demo" priority="50">
  <link home="~/.demo.conf" wtool="~/.wtool/.demo.conf" subproject="demo.conf"/>
</wtool>
XML
printf 'output/\nrelease/\n' > "$P/.gitignore"
git -C "$P" init -q; git -C "$P" remote add origin https://github.com/fakeowner/demo.git
git -C "$P" add -A; git -C "$P" -c user.name=t -c user.email=t@t commit -qm init
export WTOOL_ROOT="$W/ws" WTOOL_HOME="$W/h" WTOOL_STATE="$W/st"

echo "--- 3a. pack-release ---"
wtool pack-release terminal/demo --tag=v1
ls -A "$P/release"

echo "--- 3b. 假装新机器：删掉 release/ 和 output/，用 release.json + file:// 发布页走 download-release ---"
cp -f "$P"/release/*.zip "$P"/release/dist.json "$P"/release/*-hash.txt "$W/pub/" 2>/dev/null || { mkdir -p "$W/pub"; cp -f "$P"/release/*.zip "$P"/release/dist.json "$P"/release/*-hash.txt "$W/pub/"; }
python3 - "$P/release/dist.json" "$W/pub" "$P/scripts/release.json" <<'PY'
import json, sys, hashlib, os
dist, pub, out = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(dist, encoding="utf-8"))
d["base_url"] = "file://" + pub
assets = []
for name in sorted(os.listdir(pub)):
    p = os.path.join(pub, name)
    h = hashlib.sha256(open(p, "rb").read()).hexdigest()
    assets.append({"name": name, "role": "", "bytes": os.path.getsize(p), "sha256": h})
json.dump({"schema": 1, "project": "terminal/demo", "repo": "fakeowner/demo",
           "tag": "v1", "base_url": d["base_url"], "commit": d.get("commit",""),
           "packed_at": d.get("packed_at",""), "published_at": "now",
           "wtool_engine": "test", "dirty": False, "volume_size": "32M",
           "declare": d.get("declare", []), "targets": [{"target":"ubuntu_24.04"}],
           "assets": assets}, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
rm -rf "$P/release" "$P/output"
wtool download-release terminal/demo
wtool unpack-release terminal/demo
ls -l "$P/output/ubuntu_24.04/main/payload/usr/bin/demo"

echo "--- 3c. 表格 + dry-run + 校验 ---"
wtool | head -12
wtool validate "$P"
wtool install terminal/demo --dry-run | head -8

echo "--- 3d. 旧名字必须 die + 指路 ---"
for c in download publish provision scaffold; do
  printf '%-10s → ' "$c"; wtool $c 2>&1 | head -1 || true
done

say "3e. install → 检查影子 HOME 与 $HOME 软链 → uninstall 完全回退"
wtool install terminal/demo
printf '影子 HOME : %s\n' "$(readlink -f "$WTOOL_HOME/.wtool/.demo.conf")"
printf '家目录软链: %s（WTOOL_HOME=%s）\n' "$(readlink "$WTOOL_HOME/.demo.conf")" "$WTOOL_HOME"
[ -f "$WTOOL_HOME/.wtool/.demo.conf" ] && [ -L "$WTOOL_HOME/.demo.conf" ] \
    || { echo "❌ 没装上"; exit 1; }
wtool uninstall terminal/demo
if [ -e "$WTOOL_HOME/.demo.conf" ] || [ -e "$WTOOL_HOME/.wtool/.demo.conf" ]; then
    echo "❌ uninstall 没撤干净"; exit 1
fi
echo "✅ 装得上、撤得干净（安装落点跟着 WTOOL_HOME 走，没碰真 \$HOME）"

say "3f. 没有 docker 的机器上，声明 kind=docker 的项目必须在动手之前就被拦住（需求 4）"
mkdir -p "$W/ws/editor/dockerdemo/scripts"
cat > "$W/ws/editor/dockerdemo/wtool.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="editor/dockerdemo" priority="50"><build kind="docker"/></wtool>
XML
printf '#!/bin/sh\ntouch "$WTOOL_PROJECT_DIR/ran-anyway.txt"\n' > "$W/ws/editor/dockerdemo/scripts/build.sh"
chmod +x "$W/ws/editor/dockerdemo/scripts/build.sh"
echo "容器里 docker: $(command -v docker || echo 没有)"
_rc=0; wtool build editor/dockerdemo || _rc=$?
echo "退出码: $_rc"
if [ "$_rc" = 0 ]; then echo "❌ 没有 docker 却报成功"; exit 1; fi
[ -f "$W/ws/editor/dockerdemo/ran-anyway.txt" ] && { echo "❌ build.sh 还是跑了"; exit 1; }
echo "✅ 拒绝了，而且 build.sh 一行都没跑"
echo "--- 同一台机器上 kind=local 的项目照编 ---"
sed -i 's|<build kind="docker"/>|<build kind="local" min-cores="1" min-mem="1" min-disk="1"/>|' "$W/ws/editor/dockerdemo/wtool.xml"
wtool build editor/dockerdemo
[ -f "$W/ws/editor/dockerdemo/ran-anyway.txt" ] && echo "✅ local 项目编了" || { echo "❌ local 项目没编"; exit 1; }
echo "--- 工作区里真项目的声明也要拦住（astronvim 声明了 docker）---"
WTOOL_ROOT=/wtool wtool build editor/astronvim_v5 2>&1 | head -8 || true
echo "--- 而它连现成的包都还没有（BL-030）时，download 那条路也要说实话 ---"
WTOOL_ROOT=/wtool wtool download-release editor/astronvim_v5 --dry-run 2>&1 | head -8 || true

say "3g. 层命令在没有 docker 的机器上的说法"
wtool layer-save terminal/demo --image=whatever 2>&1 | head -2 || true

say "3h. 需求 2 的形状：install 认项目 id，也认 all"
wtool install terminal/demo >/dev/null && echo "✅ install <项目 id> 能装" || { echo "❌ install <id> 不行"; exit 1; }
wtool uninstall --id terminal/demo >/dev/null 2>&1 || true
[ -e "$WTOOL_HOME/.demo.conf" ] && { echo "❌ uninstall 没撤掉"; exit 1; } || echo "✅ uninstall --id 撤掉了"
wtool install all 2>&1 | tail -3
[ -f "$WTOOL_HOME/.wtool/.demo.conf" ] && echo "✅ install all 装上了（= wtool bootstrap）" || { echo "❌ install all 不行"; exit 1; }

say "4. 真工作区里的项目（这一条只看它说不说实话，不动网络、不写文件）"
echo "--- 4a. 项目表里的 astronvim（它声明了 <build kind=\"docker\"/>）---"
WTOOL_ROOT=/wtool wtool | head -12
echo "--- 4b. download-release --dry-run：它必须承认还没有现成的包（BL-030）---"
WTOOL_ROOT=/wtool wtool download-release editor/astronvim_v5 --dry-run 2>&1 | head -5 || true
[ -f /wtool/editor/astronvim_v5/scripts/release.json ] \
    && echo "有 release.json" || echo "✅ 没有 release.json —— 所以只能用 build，而 build 需要 docker（3f 已验）"

say "5. 系统层：sudo-install / sudo-bootstrap（2026-10-04 补 —— 这一段以前没人验，两个 bug 就是这么漏到你手里的）"
#   这一段**不装 os/ubuntu 那几百 MB**（那是几分钟的事，验收里不值得），
#   只验机制：计划对不对 / 换源会不会重复 / 真跑一个 task / 撤得干净。
#   用户这边真正会跑的 `wtool sudo-bootstrap` 由它每个项目的 sudo-install 组成，
#   这里用一个临时项目把同一条路径走通。

Z=$(mktemp -d); mkdir -p "$Z/ws/terminal/sudodemo/provision" "$Z/h" "$Z/st"
ZS="$Z/ws/terminal/sudodemo"
printf '#!/bin/sh\ntouch "$WTOOL_PROJECT_DIR/task-ran.txt"\n' > "$ZS/provision/base.sh"
printf 'demo-system-file\n' > "$ZS/demo.conf"
cat > "$ZS/wtool.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="terminal/sudodemo" priority="50">
  <sudo-install src="demo.conf" dest="/tmp/wtool-accept-demo.conf" mode="replace" backup="true"
                desc="验收用系统文件"/>
  <sudo-install src="provision/base.sh" marker="accept-base" desc="验收用任务"/>
</wtool>
XML
git -C "$ZS" init -q; git -C "$ZS" add -A
git -C "$ZS" -c user.name=t -c user.email=t@t commit -qm init
export WTOOL_ROOT="$Z/ws" WTOOL_HOME="$Z/h" WTOOL_STATE="$Z/st"

echo "--- 5a. --dry-run：只说不做 ---"
wtool sudo-install terminal/sudodemo --dry-run 2>&1 | tail -6
[ -e /tmp/wtool-accept-demo.conf ] && { echo "❌ dry-run 居然写了 /etc 之外的系统文件"; exit 1; } \
    || echo "✅ dry-run 什么都没写"

echo "--- 5b. 真跑一遍：系统文件 + 任务（task 写 marker，第二次要跳过）---"
wtool sudo-install terminal/sudodemo 2>&1 | tail -8
[ -f /tmp/wtool-accept-demo.conf ] && echo "✅ 系统文件写上了" || { echo "❌ 系统文件没写"; exit 1; }
[ -f "$ZS/task-ran.txt" ] && echo "✅ 任务真的跑了" || { echo "❌ 任务没跑"; exit 1; }
[ -f "$WTOOL_STATE/terminal/sudodemo/provisioned/accept-base" ] \
    && echo "✅ 记了 marker（幂等依据）" || { echo "❌ 没记 marker"; exit 1; }
[ -s "$WTOOL_STATE/terminal/sudodemo/system.tsv" ] \
    && echo "✅ 系统文件进了 system.tsv（sudo-uninstall 的依据）" || { echo "❌ 没有 system.tsv"; exit 1; }

echo "--- 5c. 再跑一遍：marker 在 → 任务跳过（幂等）---"
rm -f "$ZS/task-ran.txt"
wtool sudo-install terminal/sudodemo 2>&1 | grep -E "已装过|跳过" | head -3
[ -e "$ZS/task-ran.txt" ] && { echo "❌ 第二遍又把任务跑了一遍"; exit 1; } || echo "✅ 第二遍跳过了（marker 起作用）"

echo "--- 5d. sudo-uninstall：系统文件还原 + 账清掉 ---"
rm -f /tmp/wtool-accept-demo.conf
wtool sudo-uninstall terminal/sudodemo 2>&1 | tail -5
[ -e /tmp/wtool-accept-demo.conf ] && echo "✅ 系统文件还原回来了" || echo "（原来没有备份 ← 第一次是新建的，正常）"

echo "--- 5e. ★换源只有一处逻辑：install.sh 已经换过 → 系统层跳过（ADR-0032）---"
if [ -f "$WTOOL_STATE/mirror.txt" ] || [ -f "$HOME/.local/state/wtool/mirror.txt" ]; then
    echo "install.sh 记下的选择：$(cat "$WTOOL_STATE/mirror.txt" 2>/dev/null || cat "$HOME/.local/state/wtool/mirror.txt")"
else
    echo "（这台机器上 install.sh 没记过 —— 可能是选了官方源，或跑的是老版本）"
fi
# 用真工作区里的 os/ubuntu 出一次计划：有记录就该是 dedup（跳过），没记录才是 replace
WT_S=$( [ -f "$WTOOL_STATE/mirror.txt" ] && echo "$WTOOL_STATE" || echo "$HOME/.local/state/wtool" )
mkdir -p /tmp/wtool-accept-sc
python3 /wtool/bootstrap/lib/wtool_plan.py plan-provision /wtool/os/ubuntu \
    --home "$HOME" --state "$WT_S" --scratch /tmp/wtool-accept-sc \
    --os-id ubuntu --os-codename noble --arch x86_64 2>&1 | grep -E "已经换过源|选了官方源|actions" | head -4
_act=$(cut -f1 /tmp/wtool-accept-sc/sysfiles.tsv 2>/dev/null | head -1)
case $_act in
    dedup) echo "✅ os/ubuntu 认出了 install.sh 换过的源，只发 dedup（不会再写第二份）" ;;
    replace) echo "⚠️  这次是 replace（这台机器没有 mirror.txt 记录）—— 老默认 ustc，行为正确" ;;
    *) echo "⚠️  计划里的第一步是 [$_act]" ;;
esac

say "6. 验收结束"
rm -rf "$W" "$Z" /tmp/wtool-accept-sc /tmp/wtool-accept-demo.conf
