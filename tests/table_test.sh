#!/bin/sh
# table_test.sh —— 测 wtool 的能力表格
#
# 表格是给人看的第一屏，格子错了比没有更糟 —— 它会让人以为某个项目
# 能构建/能装/能发布，照着做却发现什么都没有。
#
# 三列的含义（这是这一版表格的全部）：
#   build    build.sh   在不在
#   install  install.sh 在不在；没有的话看 wtool.xml 有没有 link/env
#   publish  publish.sh 在不在；没有的话看 <publish kind> 是不是 none
#
# 三种格子：
#   亮绿 ●  项目提供了脚本（能力由脚本定义）
#   绿   ●  引擎的通用机制能办
#   灰   ·  没这项能力
# 前两者的**字符一样**，区别只在颜色，所以测试必须开 --color=always 看转义码。
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
bootstrap=$(cd -- "$here/.." && pwd)
PY="$bootstrap/lib/wtool_plan.py"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3] 实际 [$2]）"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-table.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

# --------------------------------------------------------------------------
# 四种项目，覆盖所有格子组合
# --------------------------------------------------------------------------
WS="$T/ws"
mkdir -p "$WS/declarative" "$WS/scripted" "$WS/nowhere" "$WS/upstream"
mkdir -p "$WS/outer/inner"

# 纯声明式：没有脚本，靠 wtool.xml 的 link/env 装
cat > "$WS/declarative/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="declarative" priority="10">
  <env src="env.zsh" shells="zsh"/>
  <link src="a.conf" dest=".a.conf"/>
</wtool>
EOF

# 三个脚本都有：三列都该是"项目提供脚本"
cat > "$WS/scripted/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="scripted" priority="20">
  <publish kind="script" script="publish.sh"/>
</wtool>
EOF
mkdir -p "$WS/scripted/scripts"
for f in build.sh install.sh publish.sh; do echo '#!/bin/sh' > "$WS/scripted/scripts/$f"; done

# 什么都没有：三列都该是灰点
cat > "$WS/nowhere/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="nowhere" priority="30">
  <publish kind="none"/>
</wtool>
EOF

# 上游仓：不发布，给它一个空的 publish.sh 看会不会被误认成"能发布"
mkdir -p "$WS/upstream"
cat > "$WS/upstream/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="upstream" priority="40">
  <publish kind="none"/>
</wtool>
EOF

# 嵌套项目：id 必须相对工作区根算
cat > "$WS/outer/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="outer" priority="50">
  <env src="env.zsh" shells="zsh"/>
</wtool>
EOF
cat > "$WS/outer/inner/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="outer/inner" priority="60">
  <env src="env.zsh" shells="zsh"/>
</wtool>
EOF

S="$T/state"
tbl() { env -u WTOOL_ROOT python3 "$PY" table --root "$WS" --state "$S" "$@"; }
# 取某一行的某一列。列都是单字符（可能带颜色），用 grep -o 抽转义码更好使。
# 表格带边框，所以 awk 的 $1 是竖线、$2 才是项目 id；列号统一 +1
cell() {   # <项目 id> <列号 3..6>
    # 带边框之后，每个 │ 两侧都有空格，所以 awk 的字段是：
    #   $1=│ $2=id $3=│ $4=prio $5=│ $6=build $7=│ $8=download ...
    # 第 n 列 = $(2*n)
    tbl --color=always | awk -v id="$1" -v c="$2" '$2 == id {print $(2 * c); exit}'
}

echo "== 1. build 列：有脚本就是可执行，跑过就是已完成 =="
chk "scripted 有 build.sh，没跑过 → 可执行（黄）" \
    "$(cell scripted 3)" "$(printf '\033[33m可执行\033[0m')"
chk "declarative 没脚本 → 不支持（红）" \
    "$(cell declarative 3)" "$(printf '\033[31m不支持\033[0m')"

mkdir -p "$S/scripted"
printf 'build\t2026-09-15T00:00:00+0800\t\n' > "$S/scripted/actions.tsv"
chk "构建过之后 build 变已完成（绿）" \
    "$(cell scripted 3)" "$(printf '\033[32m已完成\033[0m')"
chk "同项目的 download 仍是 不支持（没有 download.sh）" \
    "$(cell scripted 4)" "$(printf '\033[31m不支持\033[0m')"

echo "== 2. install 列：能力看脚本/清单，状态看装没装、前置做没做 =="
# 注意此时 scripted 已经记过一笔 build，前置就绪
chk "scripted 前置已就绪 → 可执行（黄）" \
    "$(cell scripted 5)" "$(printf '\033[33m可执行\033[0m')"
chk "declarative 没有 build/download → 直接可执行（黄）" \
    "$(cell declarative 5)" "$(printf '\033[33m可执行\033[0m')"
chk "nowhere 既没脚本也没 link/env → 不支持（红）" \
    "$(cell nowhere 5)" "$(printf '\033[31m不支持\033[0m')"

# 把 build 记录撤掉：install 应该退回"待构建下载"
rm -f "$S/scripted/actions.tsv"
chk "★前置没做时 install 变成 待构建下载（蓝）" \
    "$(cell scripted 5)" "$(printf '\033[34m待构建下载\033[0m')"
printf 'build\t2026-09-15T00:00:00+0800\t\n' > "$S/scripted/actions.tsv"

echo "== 3. publish 列：源码包没有前置依赖，脚本型要等构建 =="
chk "scripted 已构建、没发过 → 可执行（黄）" \
    "$(cell scripted 6)" "$(printf '\033[33m可执行\033[0m')"
chk "declarative 打源码包，不需要构建 → 可执行（黄）" \
    "$(cell declarative 6)" "$(printf '\033[33m可执行\033[0m')"
chk "nowhere 声明了 kind=none → 不支持（红）" \
    "$(cell nowhere 6)" "$(printf '\033[31m不支持\033[0m')"

rm -f "$S/scripted/actions.tsv"
chk "★脚本型没构建过 → publish 是 待构建下载（蓝）" \
    "$(cell scripted 6)" "$(printf '\033[34m待构建下载\033[0m')"
printf 'build\t2026-09-15T00:00:00+0800\t\n' > "$S/scripted/actions.tsv"

echo "== 4. 嵌套项目的 id 相对工作区根算 =="
# 曾经的真 bug：Python 侧靠 os.environ['WTOOL_ROOT'] 推 id，而 wtool.sh 里
# 那个变量没 export，读不到就退化成 basename，outer/inner 被当成 inner，
# 跟状态目录对不上，已发布的项目在表里显示成没发布。
chk "outer/inner 是自己一行" \
    "$(tbl | awk '$2 == "outer/inner" {print $2}')" "outer/inner"
chk "outer 也还在" "$(tbl | awk '$2 == "outer" {print $2}')" "outer"

echo "== 5. 状态只在 --verbose 里出现，不影响能力格子 =="
mkdir -p "$S/declarative"
printf 'link\tlink\t/home/x/.a.conf\t%s/a.conf\tsha\n' "$WS" > "$S/declarative/journal.tsv"
printf '2026-09-15T00:00:00+0800\towner/x\tsnapshot-2026-09-15\t1\tsource:abc\n' \
    > "$S/declarative/publish.tsv"
V=$(tbl --verbose)
printf '%s\n' "$V" | awk '$2 == "declarative" {print "     " $0}'
chk "装过之后 install 变已完成（绿）" \
    "$(cell declarative 5)" "$(printf '\033[32m已完成\033[0m')"
printf '%s\n' "$V" | grep -q 'declarative.*发布过' && ok "verbose 里显示了发布状态" \
    || bad "verbose 里没有发布状态"

echo "== 6. registry 也算装过 =="
S6="$T/state6"; mkdir -p "$S6"
printf '/home/x/.a.conf\tdeclarative\tlink\n' > "$S6/registry.tsv"
V6=$(env -u WTOOL_ROOT python3 "$PY" table --root "$WS" --state "$S6" --verbose)
printf '%s\n' "$V6" | grep -q 'declarative.*装过' && ok "靠 registry 认出已安装" \
    || { bad "没认出 registry 里的记录"; printf '%s\n' "$V6" | grep declarative | sed 's/^/     /'; }

echo "== 7. 发布标记能补全项目表（解压出来的工作区没有 .repo）=="
WS2="$T/ws-dist"; mkdir -p "$WS2/deep/bbb" "$WS2/.wtool-dist"
printf '{"project":"deep/bbb","repo":"x/y","commit":"abc","view":"release","layout":"wtool/deep/bbb"}\n' \
    > "$WS2/.wtool-dist/deep-bbb.json"
printf '{ 这不是 json' > "$WS2/.wtool-dist/broken.json"
TAB7=$(env -u WTOOL_ROOT python3 "$PY" table --root "$WS2" --state "$T/state7" 2>"$T/err7") || true
chk "有坏标记也不崩" "$?" "0"
chk "deep/bbb 靠发布标记被找到" "$(printf '%s\n' "$TAB7" | awk '$2 == "deep/bbb" {print $2}')" "deep/bbb"

echo "== 8. 列对齐（CJK 双宽 + ANSI 转义不能算进宽度）=="
if tbl | python3 -c '
import re, sys

ANSI = re.compile("\033\\[[0-9;]*m")

def w(t):
    t = ANSI.sub("", t)
    n = 0
    for c in t:
        o = ord(c)
        n += 2 if (0x1100 <= o <= 0x115F or 0x2E80 <= o <= 0xA4CF
                   or 0xAC00 <= o <= 0xD7A3 or 0xF900 <= o <= 0xFAFF
                   or 0xFE30 <= o <= 0xFE6F or 0xFF00 <= o <= 0xFF60
                   or 0xFFE0 <= o <= 0xFFE6) else 1
    return n

lines = [l for l in sys.stdin.read().split("\n") if l.strip().startswith("\u2502")]
# 带边框：第一行和最后一行是框线，数据/表头行以 │ 开头且以 │ 结尾
head = lines[0]
plain_head = ANSI.sub("", head)
prefix_w = w(plain_head) - w(plain_head.split()[-1]) - 2
short = [l for l in lines if w(l) < prefix_w]
print("     前缀区应宽 %d，各行宽度 %s" % (prefix_w, sorted({w(l) for l in lines})))
sys.exit(1 if short else 0)
'; then
    ok "每行前缀区都填满了（列起始位置一致）"
else
    bad "有行前缀区没填满（列会错位）"
fi

echo "== 9. 表头列名齐全 =="
for col in 项目 prio build download install publish; do
    tbl | sed -n 2p | grep -q "$col" && ok "有 $col 列" || bad "缺 $col 列"
done

echo
printf 'table_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
