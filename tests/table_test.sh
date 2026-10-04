#!/bin/sh
# table_test.sh —— 测 wtool 的能力表格
#
# 表格是给人看的第一屏，格子错了比没有更糟 —— 它会让人以为某个项目
# 能构建/能装，照着做却发现什么都没有。
#
# 这一版表格只有四列（见 harness/docs/adr/0023：download / publish 两列退休，
# 发布由引擎统一做，不再是一项"项目能力"）：
#   项目 / prio   项目 id（相对工作区根算）和优先级
#   build         有 scripts/build.sh（或项目根的老位置）→ 可执行
#                 state 里记过 build                             → 已完成
#   install       没有 install.sh 也没有 <link>/<env> 声明 → 不支持
#                 已经装过（state 里记着）                → 已完成
#                 有 build.sh 但 <项目>/output/ 是空的    → 待产出
#                 其余                                     → 可执行
#                 ⚠️ 判据是**看磁盘**（output/ 里有没有东西），
#                    不是"build 做过没有" —— 和 `wtool install` 自己
#                    的判据是同一件事，第 3 节会真跑一遍对账。
#
# 格子取值的四种标签（终端里带颜色）：
#   不支持  红   这个项目没这项能力
#   可执行  黄   现在就能跑
#   待产出  蓝   能力有，但要先把 output/ 产出来
#   已完成  绿   跑过了
# 颜色是这些格子唯一的区别（字符一样），所以测试一律开 --color=always 看转义码。
#
# ⚠️ 全程在临时工作区 + 临时 $WTOOL_HOME/$WTOOL_STATE 里跑，绝不碰真 $HOME/真工作区。
set -eu

# 先把外面可能残留的 WTOOL_* 清掉：跑测试的人可能刚在真工作区里跑过 wtool，
# 那些变量指到真 $HOME / 真 state，测试就变成在真东西上动手了（踩过）。
for _v in $(env | grep -o '^WTOOL_[A-Za-z_]*' || true); do unset "$_v"; done

here=$(cd -- "$(dirname -- "$0")" && pwd)
bootstrap=$(cd -- "$here/.." && pwd)
PY="$bootstrap/lib/wtool_plan.py"
WT="$bootstrap/wtool.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3] 实际 [$2]）"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-table.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

WS="$T/ws"
S="$T/state"
# 第 3 节要**真跑** wtool install —— 它会往这两个临时目录里铺东西（这正是要验的）
export WTOOL_HOME="$T/home" WTOOL_STATE="$S" WTOOL_ROOT="$WS"
mkdir -p "$WTOOL_HOME" "$S" "$WS"
printf '# 用户自己的 zshrc\nsetopt auto_cd\n' > "$WTOOL_HOME/.zshrc"

# 四种格子的标签（带颜色）。颜色错了也是错，所以逐个写死。
C_NONE=$(printf '\033[31m不支持\033[0m')
C_CAN=$(printf '\033[33m可执行\033[0m')
C_TODO=$(printf '\033[34m待产出\033[0m')
C_DONE=$(printf '\033[32m已完成\033[0m')

# --------------------------------------------------------------------------
# 项目夹具：覆盖四个格子的组合
#
# scripted / pending / ready 三个项目的脚本**完全一样**，差别只在 output/：
#   scripted  一开头也是空的，第 2、3 节现场给它放产物，看格子跟着翻
#   pending   output/ 空           → install 待产出
#   ready     output/ 里有产物     → install 可执行
# 两个项目之间只差磁盘上有没有东西，这就是新判据的全部。
# --------------------------------------------------------------------------
mkdir -p "$WS/declarative" "$WS/nowhere" "$WS/legacy" "$WS/outer/inner" \
         "$WS/ready/output" "$WS/needsudo/provision"

# 有 build.sh + install.sh 的项目（脚本内容无所谓：表格只问"在不在"）
mkbuildable() {   # <项目目录>
    mkdir -p "$1/scripts"
    printf '#!/bin/sh\n' > "$1/scripts/build.sh"
    printf '#!/bin/sh\n' > "$1/scripts/install.sh"
}

# 纯声明式：没有脚本，靠 wtool.xml 的 link/env 装。没有 build.sh → 不用等产出
cat > "$WS/declarative/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="declarative" priority="10">
  <env src="env.zsh" shells="zsh"/>
  <link src="a.conf" dest=".a.conf"/>
</wtool>
EOF

# 有 build.sh + install.sh，但 output/ 是空的（要真跑 install，所以得是 git 仓库）
mkbuildable "$WS/scripted"
cat > "$WS/scripted/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="scripted" priority="20"/>
EOF
git -C "$WS/scripted" init -q 2>/dev/null || true

# 和 scripted 一模一样，但 output/ 空着 → install 该是"待产出"
mkbuildable "$WS/pending"
cat > "$WS/pending/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="pending" priority="25"/>
EOF

# 和 pending 一模一样，只多了 output/x → install 该是"可执行"
mkbuildable "$WS/ready"
printf 'built\n' > "$WS/ready/output/x"
cat > "$WS/ready/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="ready" priority="28"/>
EOF

# 声明了系统层的项目：sudo 那格该是"可执行"，第 3/5 段该列出它
cat > "$WS/needsudo/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="needsudo" priority="35">
  <sudo-install kind="apt-mirror" mirror="ustc" dest="auto" desc="换源"/>
  <sudo-install src="provision/packages.yaml" marker="apt-base" desc="基础软件包"/>
</wtool>
EOF
printf -- '- hosts: localhost\n' > "$WS/needsudo/provision/packages.yaml"

# 什么都没有：两列都该是"不支持"（红）
cat > "$WS/nowhere/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="nowhere" priority="30">
  <publish kind="none"/>
</wtool>
EOF

# 老位置：build.sh 就放在项目根（不在 scripts/ 下）—— 引擎仍然认，表格也该认
cat > "$WS/legacy/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="legacy" priority="40">
  <publish kind="none"/>
</wtool>
EOF
printf '#!/bin/sh\n' > "$WS/legacy/build.sh"

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

tbl() { env -u WTOOL_ROOT python3 "$PY" table --root "$WS" --state "$S" "$@"; }
# 看板有好几张表，取列的时候只能看**第 1 张**（能力表），
# 否则后面几段里同名的项目行会把 awk 匹配走。
tbl1() { tbl "$@" | awk 'BEGIN{n=0} /^┌/{n++} n==1{print}'; }
# 取某一行的某一列。列都是带颜色的中文词，用 awk 字段切最省事。
# 表格带边框，所以 awk 的字段是：
#   $1=│ $2=id $3=│ $4=prio $5=│ $6=build $7=│ $8=install $10=sudo $12=pack
#   $14=publish $16=download $18=layer
# 第 n 列 = $(2*n)
cell() {   # <项目 id> <列号 3..9>
    tbl1 --color=always | awk -v id="$1" -v c="$2" '$2 == id {print $(2 * c); exit}'
}
# 某一列等于某个标签的那些行，按 id 排好（用来一次比对一整组，比数个数更严）
ids_where() {   # <列号> <带色标签>
    tbl1 --color=always | awk -v c="$1" -v v="$2" '$(2 * c) == v {print $2}' \
        | LC_ALL=C sort
}
count_where() { ids_where "$@" | wc -l | tr -d ' '; }

echo "== 1. build 列：有脚本就是可执行，跑过就是已完成 =="
chk "scripted 有 scripts/build.sh，没跑过 → 可执行（黄）" \
    "$(cell scripted 3)" "$C_CAN"
chk "declarative 没脚本 → 不支持（红）" \
    "$(cell declarative 3)" "$C_NONE"
chk "legacy 的 build.sh 在项目根（老位置）→ 也认 可执行（黄）" \
    "$(cell legacy 3)" "$C_CAN"

mkdir -p "$S/scripted"
printf 'build\t2026-09-15T00:00:00+0800\t\n' > "$S/scripted/actions.tsv"
chk "构建过之后 build 变已完成（绿）" \
    "$(cell scripted 3)" "$C_DONE"

echo "== 2. install 列：能力看脚本/清单，状态**看磁盘**（output/）=="
# scripted 此刻 state 里已经记过一笔 build，但 output/ 还是空的 ——
# 旧的判据（"build 做过没有"）在这里会说"可执行"，新判据（看磁盘）必须说"待产出"。
chk "★记过 build 但 output/ 空 → 待产出（蓝），不是可执行" \
    "$(cell scripted 4)" "$C_TODO"
chk "pending 一样有 build.sh、output/ 空 → 待产出（蓝）" \
    "$(cell pending 4)" "$C_TODO"
chk "ready 也有 build.sh，但 output/ 里有东西 → 可执行（黄）" \
    "$(cell ready 4)" "$C_CAN"
chk "declarative 没有 build.sh → 不用等产出，直接可执行（黄）" \
    "$(cell declarative 4)" "$C_CAN"
chk "nowhere 既没脚本也没 link/env → 不支持（红）" \
    "$(cell nowhere 4)" "$C_NONE"

# 给 scripted 放一个产物：格子必须立刻从"待产出"翻成"可执行"
mkdir -p "$WS/scripted/output"; printf 'built\n' > "$WS/scripted/output/x"
chk "★output/ 里有东西之后 → 可执行（黄）" \
    "$(cell scripted 4)" "$C_CAN"

echo "== 3. ★install 那一格和 wtool install 的判据是同一件事（真装一遍）=="
# 判据一致才叫"格子没骗人"：格子说"待产出"的时候 wtool install 必须真的拒绝，
# 放了产物它才该成功，成功之后格子才是"已完成"。全程只用临时 $WTOOL_HOME。
rm -rf -- "$WS/scripted/output"
chk "清掉 output/ → 格子退回 待产出（蓝）" \
    "$(cell scripted 4)" "$C_TODO"

_rc=0
sh "$WT" install "$WS/scripted" > "$T/install-empty.log" 2>&1 || _rc=$?
if [ "$_rc" -ne 0 ]; then
    ok "output/ 空时 wtool install 拒绝执行（退出码 $_rc）"
else
    bad "output/ 空时 wtool install 居然成功了" "$(tail -2 "$T/install-empty.log")"
fi
grep -q 'output/ 是空的' "$T/install-empty.log" \
    && ok "拒绝的理由说清了是 output/ 空的" \
    || bad "拒绝的理由没提 output/" "$(tail -2 "$T/install-empty.log")"

mkdir -p "$WS/scripted/output"; printf 'built\n' > "$WS/scripted/output/x"
chk "放了 output/x → 格子变 可执行（黄）" \
    "$(cell scripted 4)" "$C_CAN"

_rc=0
sh "$WT" install "$WS/scripted" > "$T/install-ok.log" 2>&1 || _rc=$?
if [ "$_rc" -eq 0 ]; then
    ok "有产物之后 wtool install 成功"
else
    bad "有产物之后 wtool install 失败（退出码 $_rc）" "$(tail -3 "$T/install-ok.log")"
fi
chk "★装过之后格子变 已完成（绿）" \
    "$(cell scripted 4)" "$C_DONE"
[ -d "$WTOOL_HOME/.wtool/wtool-work-dir/links/scripted" ] \
    && ok "东西真的铺进了临时 \$WTOOL_HOME（中转链接在）" \
    || bad "临时 \$WTOOL_HOME 里没有中转链接（install 没真跑？）"

echo "== 4. 嵌套项目的 id 相对工作区根算 =="
# 曾经的真 bug：Python 侧靠 os.environ['WTOOL_ROOT'] 推 id，而 wtool.sh 里
# 那个变量没 export，读不到就退化成 basename，outer/inner 被当成 inner，
# 跟状态目录对不上，已装过的项目在表里显示成没装过。
chk "outer/inner 是自己一行" \
    "$(tbl1 | awk '$2 == "outer/inner" {print $2}')" "outer/inner"
chk "outer 也还在" "$(tbl1 | awk '$2 == "outer" {print $2}')" "outer"

echo "== 5. 状态只在 --verbose 里出现，不影响能力格子 =="
mkdir -p "$S/declarative"
printf 'link\tlink\t/home/x/.a.conf\t%s/a.conf\tsha\n' "$WS" > "$S/declarative/journal.tsv"
printf '2026-09-15T00:00:00+0800\towner/x\tsnapshot-2026-09-15\t1\tsource:abc\n' \
    > "$S/declarative/publish.tsv"
V=$(tbl --verbose)
printf '%s\n' "$V" | awk '$2 == "declarative" {print "     " $0}'
chk "装过之后 install 变已完成（绿）" \
    "$(cell declarative 4)" "$C_DONE"
printf '%s\n' "$V" | grep -q 'declarative.*发布过' && ok "verbose 里显示了发布状态" \
    || bad "verbose 里没有发布状态"

echo "== 6. registry 也算装过 =="
S6="$T/state6"; mkdir -p "$S6"
printf '/home/x/.a.conf\tdeclarative\tlink\n' > "$S6/registry.tsv"
V6=$(env -u WTOOL_ROOT python3 "$PY" table --root "$WS" --state "$S6" --verbose)
printf '%s\n' "$V6" | grep -q 'declarative.*装过' && ok "靠 registry 认出已安装" \
    || { bad "没认出 registry 里的记录"; printf '%s\n' "$V6" | grep declarative | sed 's/^/     /'; }

echo "== 7. 项目表只认 wtool.xml —— 发布标记和 repo manifest 都不补行 =="
# 这两个来源曾经会把"没有 wtool.xml 的仓库"（上游源码、伞项目管的子仓）
# 变成独立一行。界面上该看到的只有真正的 wtool 项目。
WS2="$T/ws-dist"; mkdir -p "$WS2/deep/bbb" "$WS2/.wtool-dist"
printf '{"project":"deep/bbb","repo":"x/y","commit":"abc","view":"release","layout":"wtool/deep/bbb"}\n' \
    > "$WS2/.wtool-dist/deep-bbb.json"
printf '{ 这不是 json' > "$WS2/.wtool-dist/broken.json"
TAB7=$(env -u WTOOL_ROOT python3 "$PY" table --root "$WS2" --state "$T/state7" 2>"$T/err7") || true
chk "有坏标记也不崩" "$?" "0"
chk "只有发布标记、没有 wtool.xml → 不出现在表里" \
    "$(printf '%s\n' "$TAB7" | awk '$2 == "deep/bbb" {print $2}')" ""
chk "publish-list 也一样（两边判据必须一致）" \
    "$(env -u WTOOL_ROOT python3 "$PY" publish-list --root "$WS2" | awk -F'\t' '$2 == "deep/bbb" {print $2}')" ""

echo "== 8. 列对齐（CJK 双宽 + ANSI 转义不能算进宽度）=="
if tbl1 | python3 -c '
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

echo "== 9. 表头：逐项目的引擎命令都要在（2026-09-29 用户要求）=="
# 以前只有 build / install 两列 —— 用户看不到 sudo-install / pack-release 这些
# 同样是"逐项目"的命令。现在七列：build install sudo pack publish download layer。
for col in 项目 prio build install sudo pack publish download layer; do
    tbl1 --color=never | sed -n 2p | grep -q "$col" && ok "有 $col 列" || bad "缺 $col 列"
done
# 列名是缩写，就得有"列名=命令"的对照，否则等于让人猜
for pair in "build=wtool build" "install=wtool install" "sudo=wtool sudo-install" \
            "pack=wtool pack-release" "publish=wtool publish-release" \
            "download=wtool download-release" "layer=wtool layer-*"; do
    tbl --color=never | grep -qF "$pair" && ok "图例里有 $pair" || bad "图例缺 $pair"
done
# 「未发布」是新加的第五种格子：项目和"待产出"不是一回事（本机 vs 别人那台机器）
tbl --color=never | grep -q '未发布' && ok "有「未发布」这个格子" || bad "缺「未发布」格子"

echo "== 9b. 看板的后四段（install / sudo-install / bootstrap / sudo-bootstrap）=="
DASH=$(tbl --color=never)
for seg in "2. wtool install" "3. wtool sudo-install" "4. wtool bootstrap" "5. wtool sudo-bootstrap"; do
    printf '%s\n' "$DASH" | grep -qF "$seg" && ok "有第 $seg 段" || bad "缺第 $seg 段"
done
printf '%s\n' "$DASH" | grep -q 'wtool install' && ok "第 2 段打了 install 能装的项目" \
    || bad "第 2 段没内容"
printf '%s\n' "$DASH" | grep -q 'needsudo' && ok "sudo-install 段列出了声明系统层的项目" \
    || bad "sudo-install 段是空的（needsudo 该在）"
printf '%s\n' "$DASH" | grep -q 'sudo-bootstrap = 逐个' && ok "第 5 段说了 sudo-bootstrap 是什么" \
    || bad "第 5 段没有说明"
# 最后那两张图：**不许出现中文**（中文在等宽图里对不齐）
if printf '%s\n' "$DASH" | sed -n '/^  install$/,$p' | LC_ALL=C grep -q '[^ -~]'; then
    bad "安装/发布那两张图里出现了非 ASCII 字符"
else
    ok "两张图是纯 ASCII（等宽对得齐）"
fi
printf '%s\n' "$DASH" | grep -q 'wtool pack-release' && ok "发布了图里有 pack-release" \
    || bad "发布图缺 pack-release"
printf '%s\n' "$DASH" | grep -q 'read wtool.xml' && ok "安装图里有 read wtool.xml" \
    || bad "安装图缺 wtool.xml 那一步"

echo "== 9b2. sudo 那格：清单里有系统层声明才不是"不支持" =="
chk "needsudo 声明了系统层 → sudo 可执行（黄）" "$(cell needsudo 5)" "$C_CAN"
chk "declarative 没声明系统层 → sudo 不支持（红）" "$(cell declarative 5)" "$C_NONE"
# 跑过一次（state 里有 marker）→ 已完成
mkdir -p "$S/needsudo/provisioned"
: > "$S/needsudo/provisioned/apt-base"
chk "跑过之后 sudo 变已完成（绿）" "$(cell needsudo 5)" "$C_DONE"
printf '2026-09-29T10:00:00+0800\tprovision\t\n' > "$S/needsudo/actions.tsv"
DASH2=$(tbl --color=never)
printf '%s\n' "$DASH2" | grep -q 'needsudo' && ok "第 3/5 段里有 needsudo" \
    || bad "第 3/5 段没列出声明系统层的项目"
printf '%s\n' "$DASH2" | grep -q '1 个系统文件' && ok "sudo 段写了会装几个系统文件" \
    || bad "sudo 段没写系统文件数"
printf '%s\n' "$DASH2" | grep -q '基础软件包' && ok "sudo 段带了任务说明（desc）" \
    || bad "sudo 段没带 desc"
printf '%s\n' "$DASH2" | grep -q '重跑' && ok "跑过的项目在第 5 段显示「重跑」（幂等）" \
    || bad "第 5 段没体现出跑过"

echo "== 9c. --brief：只给一张表（doctor / bootstrap 末尾用）=="
BRIEF=$(tbl --brief --color=never)
printf '%s\n' "$BRIEF" | grep -qF "1. 每个项目能跑哪些命令" && ok "--brief 有第 1 段" \
    || bad "--brief 没有第 1 段"
printf '%s\n' "$BRIEF" | grep -qF "2. wtool install" && bad "--brief 不该有第 2 段" \
    || ok "--brief 只有第 1 段"
printf '%s\n' "$BRIEF" | grep -q '共 [0-9]* 个项目' && ok "--brief 带汇总行" || bad "--brief 缺汇总行"

echo "== 10. ★--summary 必须真的能跑，而且数字和表格对得上（回归）=="
# 崩溃过一次：把 project_caps 换成 pipeline_states 时只改了 render_table，
# table_summary 还在读已经不存在的 p["caps"]，KeyError。
# 而 wtool doctor 走的正是 --summary 这条路 —— 用户一敲就炸。
# 旧的断言只是 grep 了一行文本，python 崩了它也可能匹配到别的东西，所以没抓住。
_rc=0
_SUM=$(env -u WTOOL_ROOT python3 "$PY" table --root "$WS" --state "$S" --verbose --summary 2>"$T/sum.err") || _rc=$?
chk "--summary 退出码为 0" "$_rc" "0"
[ -s "$T/sum.err" ] && bad "stderr 有输出（疑似崩溃）: $(head -1 "$T/sum.err")" \
    || ok "stderr 干净"
printf '%s\n' "$_SUM" | grep -q '共 [0-9]* 个项目' \
    && ok "打印了汇总行" || bad "没有汇总行"
printf '%s\n' "$_SUM" | grep -q '待构建' && ok "汇总里有待构建计数" || bad "汇总缺待构建计数"

# 汇总里的"待构建"数 = build 列 == 可执行 的行数（有 build.sh、还没跑过）。
# 它和 install 列的"待产出"**不是**一个数：一个说"还没编"，一个说"还没产出"，
# 硬把它们并成一个词反而会让汇总和表格对不上。
_sum_build=$(printf '%s\n' "$_SUM" | sed -n 's/.*待构建 \([0-9][0-9]*\).*/\1/p')
_n_can_build=$(count_where 3 "$C_CAN")
chk "汇总的「待构建」数 == 表格 build 列 可执行 的行数" \
    "$_sum_build" "$_n_can_build"
[ "${_sum_build:-0}" -gt 0 ] \
    && ok "「待构建」不是 0，上面那条比对才测得到东西" \
    || bad "「待构建」是 0，上面那条比对测不到东西"

# install 列的"待产出"必须正好是"有 build.sh、能装、但 output/ 空、还没装过"的那几个。
# 夹具里只有 pending：scripted 已经装过（第 3 节），ready 有产物。
chk "待产出的正好是 output/ 空的那个项目（pending）" \
    "$(ids_where 4 "$C_TODO" | tr '\n' ' ')" "pending "

echo "== 11. ★表格只显示有 wtool.xml 的项目（回归）=="
# 曾经从 repo manifest 补全项目表之后忘了收回界面层，于是上游仓库
# （neovim/neovim）和伞项目管的子仓库都变成了独立一行。
WS4="$T/ws-onlymanifest"
mkdir -p "$WS4/real" "$WS4/.wtool-dist" "$WS4/umbrella/assets"
cat > "$WS4/real/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="real" priority="10">
  <env src="env.zsh" shells="zsh"/>
</wtool>
EOF
# 伞项目：自己管着一个没有 wtool.xml 的子仓库（<sub> 替它表态）
cat > "$WS4/umbrella/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="umbrella" priority="20">
  <publish>
    <sub path="assets" kind="source"/>
  </publish>
</wtool>
EOF
printf '{"project":"ghost","repo":"x/y","commit":"a","view":"release","layout":"wtool/ghost"}\n' \
    > "$WS4/.wtool-dist/ghost.json"
mkdir -p "$WS4/ghost"
TAB11=$(env -u WTOOL_ROOT python3 "$PY" table --root "$WS4" --state "$T/state11" 2>&1)
printf '%s\n' "$TAB11" | awk '{print "     " $0}'
# 看板有好几张表 —— 这几条只看第 1 张（能力表）
TAB11_1=$(printf '%s\n' "$TAB11" | awk 'BEGIN{n=0} /^┌/{n++} n==1{print}')
chk "有 wtool.xml 的项目在表里" \
    "$(printf '%s\n' "$TAB11_1" | awk '$2 == "real" {print $2}')" "real"
chk "伞项目在表里" \
    "$(printf '%s\n' "$TAB11_1" | awk '$2 == "umbrella" {print $2}')" "umbrella"
chk "伞项目管的子仓库**不**单独成行" \
    "$(printf '%s\n' "$TAB11_1" | awk '$2 == "umbrella/assets" {print $2}')" ""
chk "发布标记补全出来的项目也不成行" \
    "$(printf '%s\n' "$TAB11_1" | awk '$2 == "ghost" {print $2}')" ""

echo
printf 'table_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
