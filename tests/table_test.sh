#!/bin/sh
# table_test.sh —— 测 wtool 的能力表格
#
# 表格是给人看的第一屏，格子的语义错了比没有更糟（会让人以为装过了）。
# 这里用假 state 目录造出"装过/provision 过/发布过"三种状态，逐个格子对。
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
bootstrap=$(cd -- "$here/.." && pwd)
WT="$bootstrap/wtool.sh"
PY="$bootstrap/lib/wtool_plan.py"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3] 实际 [$2]）"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-table.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

# 造一个干净的小工作区，避免依赖真实仓库的状态
WS="$T/ws"
mkdir -p "$WS/alpha" "$WS/beta" "$WS/gamma" "$WS/delta"
cat > "$WS/alpha/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="alpha" priority="10">
  <env src="env.zsh" shells="zsh"/>
  <link src="a.conf" dest=".a.conf"/>
</wtool>
EOF
cat > "$WS/beta/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="beta" priority="20">
  <provision src="pkg.yaml" runner="ansible" marker="beta-1"/>
</wtool>
EOF
cat > "$WS/gamma/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="gamma" priority="30">
  <publish kind="none"/>
</wtool>
EOF
# delta 有发布声明但没 wtool.xml 之外的东西，用它验"走脚本"
cat > "$WS/delta/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="delta" priority="40">
  <publish kind="script" script="publish.sh"/>
</wtool>
EOF

S="$T/state"

echo "== 1. 什么都没做：install/provision/publish 全是 -（能做没做）=="
TAB=$(python3 "$PY" table --root "$WS" --state "$S")
echo "$TAB" | sed 's/^/     /'
row() { printf '%s\n' "$TAB" | awk -v id="$1" '$1 == id {print; exit}'; }
chk "alpha 的 install 是 -" "$(row alpha | awk '{print $3}')" "-"
chk "alpha 的 provision 是 .（清单里没有 provision）" "$(row alpha | awk '{print $4}')" "."
chk "beta 的 provision 是 -（有 provision 但没跑）" "$(row beta | awk '{print $4}')" "-"
chk "gamma 的 publish 是 .（声明了不发布）" "$(row gamma | awk '{print $5}')" "."
chk "delta 的 publish 是 -（能发没发）" "$(row delta | awk '{print $5}')" "-"
chk "beta 的 install 是 .（没这项能力）" "$(row beta | awk '{print $3}')" "."

echo "== 2. 造出 装过/provision过/发布过 的状态 =="
mkdir -p "$S/alpha" "$S/beta/provisioned" "$S/delta"
printf 'link\tlink\t/home/x/.a.conf\t%s/a.conf\tsha\n' "$WS" > "$S/alpha/journal.tsv"
printf 'beta-1\t2026-09-15T00:00:00+0800\n' > "$S/beta/provisioned/beta-1"
printf '2026-09-15T00:00:00+0800\towner/repo\tsnapshot-2026-09-15\t1\tsource:abc\n' \
    > "$S/delta/publish.tsv"

TAB2=$(python3 "$PY" table --root "$WS" --state "$S")
echo "$TAB2" | sed 's/^/     /'
row2() { printf '%s\n' "$TAB2" | awk -v id="$1" '$1 == id {print; exit}'; }
chk "alpha 的 install 变成 +" "$(row2 alpha | awk '{print $3}')" "+"
chk "alpha 的 uninstall 也是 +（装了才谈得上卸）" "$(row2 alpha | awk '{print $6}')" "+"
chk "beta 的 provision 变成 +" "$(row2 beta | awk '{print $4}')" "+"
chk "delta 的 publish 变成 +" "$(row2 delta | awk '{print $5}')" "+"
chk "gamma 的 publish 还是 .（声明不发布，不是 TODO）" "$(row2 gamma | awk '{print $5}')" "."

echo "== 3. registry 也算装过（journal 不在但软链登记了）=="
# 用 alpha（它有 <link>/<env>，有 install 能力），只给它 registry 不给 journal
S3="$T/state3"; mkdir -p "$S3"
printf '/home/x/.a.conf\talpha\tlink\n' > "$S3/registry.tsv"
TAB3=$(python3 "$PY" table --root "$WS" --state "$S3")
printf '%s\n' "$TAB3" | awk '$1 == "alpha" {print "     " $0}'
chk "alpha 靠 registry 认出已安装" \
    "$(printf '%s\n' "$TAB3" | awk '$1 == "alpha" {print $3; exit}')" "+"
chk "gamma 只声明了 <publish>，本来就没有 install 能力" \
    "$(printf '%s\n' "$TAB3" | awk '$1 == "gamma" {print $3; exit}')" "."

echo "== 4. 汇总数字对得上 =="
SUM=$(python3 "$PY" table --root "$WS" --state "$S" --summary | tail -1)
echo "     $SUM"
printf '%s' "$SUM" | grep -q '共 4 个项目' && ok "项目数对" || bad "项目数不对: $SUM"
printf '%s' "$SUM" | grep -q '已安装 1' && ok "已安装数对（只有 alpha 装了）" || bad "已安装数不对: $SUM"
printf '%s' "$SUM" | grep -q '已发布 1' && ok "已发布数对（delta）" || bad "已发布数不对: $SUM"

echo "== 5. 表头列名齐全 =="
for col in 项目 prio install provision publish uninstall; do
    printf '%s\n' "$TAB" | head -1 | grep -q "$col" && ok "有 $col 列" || bad "缺 $col 列"
done

echo "== 6. 列对齐：每行在"最后一列之前"都被填满到同一宽度 =="
# 表格每行末尾会被 rstrip，所以比"整行宽度"没意义（表头最后一列 9 宽、
# 数据行只有 1 宽，这本来就是对的）。真正的不变量是：最后一列之前的区域
# 每行都填满到同样的宽度，这样各列起始位置才一致。
if printf '%s\n' "$TAB" | python3 -c '
import sys

def cw(c):
    o = ord(c)
    return 2 if (0x1100 <= o <= 0x115F or 0x2E80 <= o <= 0xA4CF
                 or 0xAC00 <= o <= 0xD7A3 or 0xF900 <= o <= 0xFAFF
                 or 0xFE30 <= o <= 0xFE6F or 0xFF00 <= o <= 0xFF60
                 or 0xFFE0 <= o <= 0xFFE6) else 1

def w(t):
    return sum(cw(c) for c in t)

lines = [l for l in sys.stdin.read().split("\n") if l.strip() and not l.startswith("-")]
head = lines[0]
# 表头最后一列的宽度 = 前缀区宽度之后的部分
prefix_w = w(head) - w(head.split()[-1]) - 2
short = [l for l in lines if w(l) < prefix_w]
print("     前缀区应宽 %d，各行宽度 %s" % (prefix_w, sorted({w(l) for l in lines})))
if short:
    print("     宽度不足的行: %r" % short[:2])
sys.exit(1 if short else 0)
'; then
    ok "每行前缀区都填满了（列起始位置一致）"
else
    bad "有行前缀区没填满（列会错位）"
fi

echo
printf 'table_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
