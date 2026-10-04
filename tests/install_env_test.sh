#!/bin/sh
# install_env_test.sh —— 测 `install.sh` 的"第 0 步：准备运行环境"（install-env.sh）
#
# 这一组守的是**换源那一段**（2026-10-04 用户要求改成"先测速再让他挑"）：
#   · 候选镜像表能解析，测速结果按**速度降序**排（这里踩过：拿字符串排负数，
#     最慢的官方源排到了第一，默认选项就成了最慢的那个）
#   · 非交互（没有终端可问）→ 自动选最快的，绝不卡在等输入上
#   · 交互 → 打印表格、问一句、按用户输入选
#   · 换源要**先备份原源**，挑的源不好用要能把原源放回去（以前是直接删掉，没退路）
#   · `WTOOL_MIRROR=<代号|主机名|official>` 能跳过测速
#
# 全程打桩 + 临时目录：
#   ENV_APT_HELPER  假 apt-helper（按"镜像名"返回不同大小/耗时，速度是确定的）
#   ENV_APT_DIR     假 /etc/apt（绝不碰真的）
#   PATH            最前面放假的 apt-get（`update` / `install` 都成功）
set -eu

for _v in $(env | grep -o '^WTOOL_[A-Za-z_]*' || true); do unset "$_v"; done

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(cd -- "$here/.." && pwd)
ENV_SH="$boot/scripts/install-env.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3] 实际 [$2]）"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-envtest.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

# ── 假 apt-helper ────────────────────────────────────────────────────────
# 只认 download-file；按 URL 里的主机名决定"下多少字节、花多少时间"。
# 速度 = 字节/毫秒，测试里可以精确算出来：
#   fast.example   2000000 字节 / 200 ms = 10000 KB/s   → 1
#   mid.example     600000 字节 / 600 ms =  1000 KB/s   → 2
#   slow.example     30000 字节 /1000 ms =    30 KB/s   → 3
#   dead.example   一个字节都不下（模拟连不上）          → n/a
cat > "$T/apt-helper" <<'EOF'
#!/bin/sh
# 用法（我们只用这一种）：apt-helper download-file [-o ...] <url> <out>
_out=""
_url=""
for _a in "$@"; do
    case $_a in
        download-file) ;;
        -o) ;;
        Acquire::*) ;;
        http*) _url=$_a ;;
        *) _out=$_a ;;
    esac
done
case $_url in
    *fast.example*)  _b=2000000; _ms=200 ;;
    *mid.example*)   _b=600000;  _ms=600 ;;
    *slow.example*)  _b=30000;   _ms=1000 ;;
    *)               _b=0;       _ms=100 ;;
esac
if [ "$_b" = 0 ]; then exit 100; fi
# 真等一下，让"用时"这件事在测试里也成立（毫秒级，不拖慢测试）
_sleep=$(awk -v ms="$_ms" 'BEGIN{printf "%.3f", ms/1000}')
sleep "$_sleep" 2>/dev/null || true
# 写够字节数（用 head -c 从 /dev/zero 要，快）
head -c "$_b" /dev/zero > "$_out" 2>/dev/null || dd if=/dev/zero of="$_out" bs=1000 count=$((_b/1000)) 2>/dev/null
exit 0
EOF
chmod +x "$T/apt-helper"

# ── 假 apt-get：换源之后的 `update` / `install` 都当成功 ────────────────
mkdir -p "$T/bin"
cat > "$T/bin/apt-get" <<'EOF'
#!/bin/sh
printf 'apt-get %s\n' "$*" >> "${ENV_APT_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$T/bin/apt-get"
# 假 sudo：能模拟四种权限状态（用户 2026-10-04 要求 install.sh 区分它们）
#   FAKE_SUDO=nopass   `sudo -n true` 成功；`sudo -n <cmd>` 原样执行
#   FAKE_SUDO=askpass  `sudo -n true` 失败；`sudo -S -v` 要 stdin 给对的密码
#   （PATH 里没有 sudo = nosudo）；FAKE_SUDO_PW 是"正确密码"（默认 root）
cat > "$T/bin/sudo" <<'EOF'
#!/bin/sh
mode=${FAKE_SUDO:-nopass}
pw_ok=${FAKE_SUDO_PW:-root}
nflag=0; vflag=0; lflag=0; args=""; seen_cmd=0
# ⚠️ 只有**命令之前**的才算 sudo 自己的开关：`sudo -n mkdir -p <目录>`
#    里的 `-p` 是 mkdir 的，第一版当成 sudo 的 -p 吃掉了后面的目录，
#    于是 mkdir 没参数、静默失败（测试里表现为 tee: No such file or directory）
while [ $# -gt 0 ]; do
    if [ "$seen_cmd" = 1 ]; then args="$args $1"; shift; continue; fi
    case $1 in
        -n) nflag=1 ;;
        -S) ;;
        -v) vflag=1 ;;
        -l) lflag=1 ;;
        -k) exit 0 ;;
        -p) shift ;;
        --) seen_cmd=1 ;;
        -*) ;;
        *) seen_cmd=1; args="$args $1" ;;
    esac
    shift
done
if [ "$lflag" = 1 ]; then
    # `sudo -n -l`：能列规则 = 在 sudoers 里（askpass = 要密码但有权限）
    [ "$mode" = askpass ] && exit 0
    exit 1
fi
if [ "$vflag" = 1 ]; then
    IFS= read -r _pw || _pw=""
    [ "$_pw" = "$pw_ok" ] && exit 0
    exit 1
fi
if [ "$nflag" = 1 ] && [ "$mode" != nopass ]; then
    exit 1
fi
[ -z "$(printf '%s' "$args" | tr -d ' ')" ] && exit 0
exec $args
EOF
chmod +x "$T/bin/sudo"

# 一份"本来就有"的源，用来验证备份/还原
mk_aptdir() {   # <目录>
    mkdir -p "$1/sources.list.d"
    printf '# 原来的源\n' > "$1/sources.list"
    printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/\n' \
        > "$1/sources.list.d/ubuntu.sources"
}

# 把候选表换掉：我们要**确定的速度**，不要真去网上测
# （测速逻辑本身用真网在容器里人工验过 —— 见 journal 第 18 轮）
cat > "$T/env_shim" <<EOF
env_mirror_list() {
    cat <<'LIST'
fast mirrors.fast.example 快
mid mirrors.mid.example 中
slow mirrors.slow.example 慢
dead mirrors.dead.example 连不上
LIST
}
EOF

# ⚠️ stdin 一律接 /dev/null：测试是在终端里跑的，`[ -t 0 ]` 会是真的，
#    那样 env_mirror_pick 会走"问用户"那条路，测试就卡在等输入上了
#    （交互那条路单独用 script 造 pty 来测，见第 2 节）。
run_env() {   # <apt 目录> [VAR=值 ...] <要调用的命令...>
    _d=$1; shift
    # 前导的 VAR=值 当环境变量（`sh -c ... WTOOL_MIRROR=mid` 会被当成命令名，
    # 实测报 "WTOOL_MIRROR=mid: not found"），其余是命令
    while [ $# -gt 0 ]; do
        case $1 in
            *=*) eval "export $1"; shift ;;
            *) break ;;
        esac
    done
    # ⚠️ state 一定要指到临时目录：`env_apt_ready` 现在会读 <state>/mirror.txt
    #    （上次挑过就接着用），不隔离就会读到**跑测试那个人自己的**记录，
    #    于是"该测速的没测速"（实测：4 条断言因此红过）。
    #   每个 fixture 的 apt 目录配一个独立 state：同一节里前后两小段（比如
    #   "先记 official、再自动挑"）才不会互相串味。
    _st=${WTOOL_STATE:-$T/state-$(basename -- "$_d")}
    mkdir -p "$_st"
    PATH="$T/bin:$PATH" \
    ENV_APT_DIR="$_d" ENV_APT_HELPER="$T/apt-helper" ENV_CODENAME=noble \
    ENV_APT_LOG="$T/apt.log" WTOOL_STATE="$_st" \
        sh -c '. "$1"; . "$2"; shift 2; "$@"' sh "$ENV_SH" "$T/env_shim" "$@" < /dev/null
}

echo "== 1. 测速表：按速度降序，最快的在第一行 =="
APT1="$T/apt1"; mk_aptdir "$APT1"
_out=$(run_env "$APT1" env_mirror_pick 2>"$T/pick.err")
chk "非交互时返回最快那个" "$_out" "fast mirrors.fast.example"
grep -q '非交互环境：自动选最快的 #1（mirrors.fast.example）' "$T/pick.err" \
    && ok "说清了是自动选的" || bad "没说自动选（$(cat "$T/pick.err")）"
# 表格里 four 个候选都在，顺序 = 快/中/慢/连不上
_order=$(sed -n 's/^  │ *[0-9]* │ \(mirrors\.[a-z.]*\) .*/\1/p' "$T/pick.err" | tr '\n' ' ')
chk "表格按速度降序" "$_order" "mirrors.fast.example mirrors.mid.example mirrors.slow.example mirrors.dead.example "
# 速度只断言"量级"：打桩的 apt-helper 本身有进程启动开销（十几毫秒），
# 200ms 那次会被算成 ~9 MB/s 而不是 10.00 —— 关键是**能算出速率、量级对**
grep -qE 'mirrors.fast.example +│ [0-9.]+ MB/s' "$T/pick.err" && ok "快的算出 MB/s 量级" \
    || bad "快的速度算错（$(grep fast "$T/pick.err")）"
grep -qE 'mirrors.slow.example +│ [0-9]+ KB/s' "$T/pick.err" && ok "慢的算出 KB/s 量级" \
    || bad "慢的速度算错（$(grep slow "$T/pick.err")）"
grep -q 'n/a' "$T/pick.err" && ok "连不上的显示成 n/a（ASCII，不会把表撑歪）" || bad "连不上没标出来"
# ⚠️ 这条是**回归**：曾经用"取负 + 字符串升序"排序，最慢的跑到了第一行
_first=$(sed -n 's/^  │ *1 │ \(mirrors\.[a-z.]*\) .*/\1/p' "$T/pick.err" | head -1)
chk "第 1 行是**最快**的，不是最慢的（回归）" "$_first" "mirrors.fast.example"

echo "== 2. 交互：有终端就问一句，按用户选的来 =="
# 用 script 造一个 pty：stdin 是终端 → 走交互分支，喂 "3" 应选中第 3 个
if command -v script >/dev/null 2>&1; then
    # pty 上提示和返回值在同一行，取最后一个全角冒号之后的部分
    _out=$(printf '3\n' | script -qec "sh -c '. $ENV_SH; . $T/env_shim; ENV_APT_DIR=$APT1 ENV_APT_HELPER=$T/apt-helper ENV_CODENAME=noble env_mirror_pick'" /dev/null 2>/dev/null | tail -1 | tr -d '\r' | sed 's/.*：//')
    chk "按用户输入选中第 3 个（慢的那个）" "$_out" "slow mirrors.slow.example"
else
    ok "没有 script 命令，跳过交互这条（其余照测）"
fi

echo "== 2b. 把选择记到状态目录（系统层要照着它来，别换第二次）=="
#   <state>/mirror.txt 是 install.sh 和系统层之间唯一的交接点：
#   项目清单里的 <sudo-install kind="apt-mirror" mirror="auto"/> 读它
#   （见 lib/wtool_plan.py 的 _recorded_mirror 和 provision_test 场景 9）。
mkdir -p "$T/state"
_out=$(run_env "$APT1" WTOOL_STATE="$T/state" env_apt_ready 2>&1)
chk "记了选中的代号" "$(cut -f1 "$T/state/mirror.txt" 2>/dev/null)" "fast"
chk "记了主机名" "$(cut -f2 "$T/state/mirror.txt" 2>/dev/null)" "mirrors.fast.example"
chk "记了来源（install.sh）" "$(cut -f3 "$T/state/mirror.txt" 2>/dev/null)" "install.sh"
rm -f "$T/state/mirror.txt"
APT1B="$T/apt1b"; mk_aptdir "$APT1B"
_out=$(run_env "$APT1B" WTOOL_STATE="$T/state" WTOOL_MIRROR=official env_apt_ready 2>&1)
chk "选官方源时记 official（系统层就知道别换）" \
    "$(cut -f1 "$T/state/mirror.txt" 2>/dev/null)" "official"

echo "== 2d. 提权：免密 / 要密码 / 没 sudo，三条路都要走通 =="
#   用户 2026-10-04：公司机器通常不能 sudo，但用户一样要用 wtool 装 tmux / zsh。
#   所以 install.sh 必须分清"要不要 root、能不能拿到 root"，并且**绝不挂住**。
mkdir -p "$T/home" "$T/state-priv"
_priv() {   # <FAKE_SUDO|-> <在 . install-env.sh 之后跑的 sh 片段>
    _pm=$1; _snip=$2
    if [ "$_pm" = "-" ]; then
        PATH=$(printf '%s' "$T/bin:$PATH" | sed "s|$T/bin:||") \
        HOME="$T/home" WTOOL_STATE="$T/state-priv" \
            sh -c ". \"\$1\"; $_snip" sh "$ENV_SH" 2>&1
    else
        PATH="$T/bin:$PATH" FAKE_SUDO="$_pm" HOME="$T/home" WTOOL_STATE="$T/state-priv" \
            sh -c ". \"\$1\"; $_snip" sh "$ENV_SH" 2>&1
    fi
}
chk "sudo 免密 → nopass，前缀 sudo -n" \
    "$(_priv nopass 'env_priv_refresh; printf "%s|%s" "$ENV_PRIV_MODE" "$ENV_PRIV"')" \
    "nopass|sudo -n "
chk "有 sudo 但要密码 → askpass" \
    "$(_priv askpass 'env_priv_refresh; printf "%s" "$ENV_PRIV_MODE"')" "askpass"
#   宿主上 /usr/bin/sudo 是存在的（而且会要密码 → 那就是 askpass）。
#   "没有 sudo 的机器"用 WTOOL_SUDO=never 表达（这也是给用户的开关）
chk "WTOOL_SUDO=never → nosudo（当没有 sudo 处理）" \
    "$(WTOOL_SUDO=never _priv nopass 'env_priv_refresh; printf "%s" "$ENV_PRIV_MODE"')" "nosudo"
_out=$(WTOOL_SUDO=never _priv nopass 'if env_priv_ask 测试; then echo "rc=0"; else echo "rc=$?"; fi')
case $_out in
    *"没有 sudo，跳过要 root 的部分"*"rc=1"*) ok "nosudo 时明确跳过（不试 sudo）" ;;
    *) bad "nosudo 时的处理不对: $_out" ;;
esac
# 要密码 + 没有终端 → 必须**明确跳过**，不能挂住、也不能当成成功
_out=$(_priv askpass 'if env_priv_ask 测试; then echo "rc=0"; else echo "rc=$?"; fi' < /dev/null)
case $_out in
    *"没有终端可以问密码"*"rc=1"*) ok "没有终端问密码 → 明确跳过（不挂住）" ;;
    *) bad "没有终端时的处理不对: $_out" ;;
esac
# 没有 sudo + 环境已齐（python3/git/curl 都在）→ **一次 apt-get 都不调**
: > "$T/apt-priv.log"
WTOOL_SUDO=never _priv nopass 'ENV_NAME="Ubuntu 24.04 (noble)"; export ENV_NAME; env_prepare' \
    > "$T/priv-prepare.log" 2>&1 || true
grep -q "运行环境已经在" "$T/priv-prepare.log" \
    && ok "环境齐时不碰 apt（不需要 root）" \
    || bad "环境齐时没走'不需要 root'那条路: $(head -3 "$T/priv-prepare.log")"
[ -s "$T/apt-priv.log" ] && bad "没有 root 却调了 apt-get" || ok "没有 root 时一次 apt-get 都没调"
grep -q "运行环境就绪" "$T/priv-prepare.log" \
    && ok "拿不到 root 也走完了第 0 步（wtool 自己能装）" \
    || bad "拿不到 root 时第 0 步没走完: $(tail -3 "$T/priv-prepare.log")"
rm -rf "$T/home" "$T/state-priv"

echo "== 3. 换源：写 deb822 + 先备份原源 =="
APT2="$T/apt2"; mk_aptdir "$APT2"
run_env "$APT2" env_use_mirror mirrors.ustc.edu.cn >/dev/null 2>&1
[ -f "$APT2/sources.list.d/wtool-mirror.sources" ] && ok "写了 wtool-mirror.sources" \
    || bad "没写源文件"
grep -q '^URIs: http://mirrors.ustc.edu.cn/ubuntu/' "$APT2/sources.list.d/wtool-mirror.sources" \
    && ok "URIs 指向选中的镜像" || bad "URIs 不对"
grep -q 'Suites: noble noble-updates' "$APT2/sources.list.d/wtool-mirror.sources" \
    && ok "带上 updates/security 那几个 suite" || bad "Suites 不全"
[ -f "$APT2/sources.list.d/ubuntu.sources" ] && bad "原来的源没清掉（换源等于没换）" \
    || ok "原来的源清掉了"
[ -f "$APT2/wtool-sources.bak/sources.list.d/ubuntu.sources" ] && ok "★原源备份下来了（有退路）" \
    || bad "没备份原源 —— 换源失败就回不去了"

echo "== 4. 挑的源不好用 → 把原源放回去 =="
run_env "$APT2" env_apt_restore_sources >/dev/null 2>&1
[ -f "$APT2/sources.list.d/ubuntu.sources" ] && ok "原来的源回来了" || bad "原源没回来"
[ -f "$APT2/sources.list.d/wtool-mirror.sources" ] && bad "镜像源还在（该清掉）" \
    || ok "镜像源清掉了"

echo "== 5. WTOOL_MIRROR：跳过测速，直接用指定的 =="
APT3="$T/apt3"; mk_aptdir "$APT3"
_out=$(run_env "$APT3" WTOOL_MIRROR=mid env_apt_ready 2>&1)
case $_out in
    *"按 WTOOL_MIRROR 指定：mirrors.mid.example"*) ok "认代号（mid → mirrors.mid.example）" ;;
    *) bad "没认代号: $_out" ;;
esac
grep -q '^URIs: http://mirrors.mid.example/ubuntu/' "$APT3/sources.list.d/wtool-mirror.sources" 2>/dev/null \
    && ok "按代号换到了 mid" || bad "代号没换成源"
APT4="$T/apt4"; mk_aptdir "$APT4"
_out=$(run_env "$APT4" WTOOL_MIRROR=official env_apt_ready 2>&1)
case $_out in
    *"保持系统自带的源"*) ok "official = 不换源" ;;
    *) bad "official 没被认出来: $_out" ;;
esac
[ -f "$APT4/sources.list.d/wtool-mirror.sources" ] && bad "official 却写了镜像源" \
    || ok "official 时没动源文件"
APT5="$T/apt5"; mk_aptdir "$APT5"
_out=$(run_env "$APT5" WTOOL_MIRROR=mirrors.fast.example env_apt_ready 2>&1)
case $_out in
    *"按 WTOOL_MIRROR 指定：mirrors.fast.example"*) ok "也认主机名" ;;
    *) bad "没认主机名: $_out" ;;
esac

echo "== 6. 自动那条路：测速 → 换源 → update 成功 =="
APT6="$T/apt6"; mk_aptdir "$APT6"
: > "$T/apt.log"
_out=$(run_env "$APT6" env_apt_ready 2>&1)
case $_out in
    *"用 mirrors.fast.example（fast）"*) ok "选了最快的那个" ;;
    *) bad "没选最快的: $_out" ;;
esac
grep -q 'apt-get update' "$T/apt.log" && ok "真的调了 apt-get update" || bad "没调 update"
case $_out in
    *"换源后可用"*) ok "update 成功 → 用这个源" ;;
    *) bad "没说成功: $_out" ;;
esac
# 换源之后 apt 必须**直连**这个镜像（走代理等于没换）
[ -f "$APT6/apt.conf.d/99wtool-noproxy" ] && grep -q 'mirrors.fast.example' "$APT6/apt.conf.d/99wtool-noproxy" \
    && ok "给这个镜像写了 DIRECT（不走代理）" || bad "没写 DIRECT"

echo "== 7. 全都连不上 → 保持系统源，不换（也不能崩） =="
cat > "$T/env_shim_dead" <<'EOF'
env_mirror_list() {
    printf 'dead mirrors.dead.example 连不上\n'
}
EOF
APT7="$T/apt7"; mk_aptdir "$APT7"
set +e
#   ⚠️ 这一条是裸 sh -c（不走 run_env），state 也要自己隔离 ——
#      不然会读到跑测试那个人自己的 ~/.local/state/wtool/mirror.txt
mkdir -p "$T/state-apt7"
_out=$(PATH="$T/bin:$PATH" ENV_APT_DIR="$APT7" ENV_APT_HELPER="$T/apt-helper" \
       ENV_CODENAME=noble WTOOL_STATE="$T/state-apt7" \
       sh -c '. "$1"; . "$2"; env_apt_ready' sh "$ENV_SH" "$T/env_shim_dead" 2>&1)
_rc=$?
set -e
chk "全连不上时退出码仍是 0（不能把安装整个搞崩）" "$_rc" "0"
case $_out in
    *"都连不上"*"保持系统自带的源"*) ok "说清了并保持系统源" ;;
    *) bad "没有兜底说法: $_out" ;;
esac
[ -f "$APT7/sources.list.d/wtool-mirror.sources" ] && bad "连不上还换了源" || ok "没动源文件"

echo "== 8. 打印给用户的"接下来敲什么"，不许漏命令（回归）=="
#   2026-10-04 用户发现：install.sh 结尾那份操作对照表里**没有 sudo-bootstrap** ——
#   而"装系统层"恰恰是新机器上必须的一步。容器脚本里的表也一样。
#   命令名以后还会变，所以这里守的是"这几处提示必须同时提到这两层"，
#   而不是死抠文案。
_scripts="$boot/scripts"
_greet_check() {   # <文件> <必须出现的字符串...>
    _gc_f=$1; shift
    for _gc_want in "$@"; do
        if grep -qF -- "$_gc_want" "$_gc_f" 2>/dev/null; then
            ok "$(basename "$_gc_f") 提到「$_gc_want」"
        else
            bad "$(basename "$_gc_f") 的提示里没有「$_gc_want」（用户会漏掉这一步）"
        fi
    done
}
_greet_check "$_scripts/install.sh" \
    "wtool sudo-bootstrap" "wtool bootstrap" "wtool uninstall" "wtool sudo-uninstall"
_greet_check "$_scripts/container-raw.sh" \
    "./install.sh" "exec \$SHELL" "wtool sudo-bootstrap" "wtool bootstrap"
_greet_check "$_scripts/container-shell.sh" \
    "wtool sudo-bootstrap" "wtool bootstrap"
# 打印的**用法**必须真的能跑，而且**不许出现 `--id`**：ADR-0037 把它整个删掉了
# （项目身份就是路径）。提示里印一个已经不存在的开关，用户照着敲就会报错。
if grep -qF -- "--id" "$_scripts/install.sh"; then
    bad "提示里出现了已经删掉的 --id（项目身份就是路径，见 ADR-0037）"
else
    ok "提示里的 sudo-uninstall 用法对（<项目>|all）"
fi
grep -qF "wtool sudo-uninstall <项目>|all" "$_scripts/install.sh" \
    && ok "写清了 sudo-uninstall 收 <项目>|all" || bad "sudo-uninstall 的用法没写清"

# container-raw.sh --user：**只做三件事** —— 建用户 / 挑源 / 装 sudo
#   （用户 2026-10-04 确认过的清单："支持新增了一个 mindul 用户，此外为了
#     下载快一些，让用户选择了源，还安装了 sudo …除此之外就没有了"）
_CR="$_scripts/container-raw.sh"
grep -qF -- "--user <用户名>" "$_CR" && grep -qF '密码 **root**' "$_CR" \
    && grep -qF 'sudo **免密**' "$_CR" \
    && ok "container-raw.sh 有 --user 用法，提示里写了密码 root / sudo 免密" \
    || bad "container-raw.sh 的 --user 用法或密码提示不全"
grep -qF 'chpasswd' "$_CR" && grep -qF 'NOPASSWD:ALL' "$_CR" \
    && ok "--user 真的会设密码 + 写 sudoers 免密" || bad "--user 缺 chpasswd / NOPASSWD"
grep -qF 'exec su - "$USER_NAME"' "$_CR" \
    && ok "--user 最后切到那个用户（su -）" || bad "--user 没有切用户"
grep -qE '^if \[ -n "\$USER_NAME" \]; then$' "$_CR" \
    && ok "三件事都在 --user 分支里（不带参数一件都不做）" \
    || bad "--user 的分支结构不对（可能不带参数也会动手）"
# 三件事之二：挑源（借用 install-env.sh 的测速 + 记录给 install.sh 复用）
grep -qF 'env_apt_ready' "$_CR" && ok "--user 会挑源（env_apt_ready）" \
    || bad "--user 没挑源（用户清单里的第二件事）"
grep -qF 'WTOOL_STATE="$USER_HOME/.local/state/wtool"' "$_CR" \
    && ok "挑源结果记在**那个用户**的 state 里（install.sh 接着用）" \
    || bad "挑源结果没记到新用户名下"
grep -qF 'command -v sudo' "$_CR" && grep -qF -- '--no-install-recommends sudo' "$_CR" \
    && ok "--user 会装 sudo 这个包（基础镜像里没有）" || bad "--user 没装 sudo"
# 三件事**之外**的：不跑 install.sh、不装别的包、不碰工作区
grep -qE '^[[:space:]]*(\./|bash |sh )?/?\$?\{?WTOOL_DIR\}?/install\.sh' "$_CR" \
    && bad "container-raw.sh 自己跑了 ./install.sh（用户说那是他自己敲的）" \
    || ok "container-raw.sh 不自己跑 ./install.sh"
for _pkg in python3 ' git ' curl ansible; do
    if grep -qE "apt-get install[^\n]*$_pkg" "$_CR"; then
        bad "container-raw.sh 装了 $_pkg（那该是 install.sh 第 0 步的事）"
    else
        ok "container-raw.sh 不装 $_pkg"
    fi
done
# 提示里那四条命令必须和不带 --user 时一样
for _c in "./install.sh" "exec \$SHELL" "wtool sudo-bootstrap" "wtool bootstrap"; do
    grep -qF -- "$_c" "$_CR" || bad "提示里少了「$_c」"
done
ok "四条命令仍在（--user 前后同一条路）"

# 反向：容器脚本里不该再出现已经退休/改名的老命令
for _old in "wtool download " "wtool publish " "wtool provision"; do
    if grep -qF -- "$_old" "$_scripts/container-raw.sh" "$_scripts/container-shell.sh" 2>/dev/null; then
        bad "容器脚本的提示里还有老命令「$_old」"
    else
        ok "容器脚本没有老命令「$_old」"
    fi
done

echo
printf 'install_env_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
