#!/bin/sh
# install-env.sh —— 给 wtool 准备运行环境的**共用逻辑**。
#
# 不单独执行，由 install.sh 选中的发行版脚本 source 进来。
# 各发行版脚本只写"自己不一样的地方"（见 install-ubuntu20.sh 那种），
# 装包、挑镜像、自举引擎这些所有发行版都一样的部分都在这里。
#
# 各 profile 要设置的变量：
#   ENV_NAME          发行版名字，给人看的（"Ubuntu 20.04 (focal)"）
#   ENV_ANSIBLE       这个版本上 ansible 的**包名**（见下面的说明）
#   ENV_EXTRA_PKGS    额外的包（可空）
#   ENV_MIRROR        可选的镜像主机名；留空就用系统自带的源
#
# 为什么 python3 之外还要装这些：
#   git           引擎要读各项目的 HEAD（发布、版本检查都靠它）
#   ca-certificates  HTTPS 必需；缺了 apt 换 https 源会证书报错
#   curl           download.sh 从发布页取包用的就是它（**不依赖 gh**）
#   ansible        os/ubuntu 用它装系统包（provision 那一步）
set -eu

# 测试用的三个钩子（真环境里就是默认值）：
#   ENV_APT_HELPER  apt-helper 的路径 —— 测速靠它下载；测试里换成打桩的
#   ENV_APT_DIR     写源/备份的地方 —— 测试里指向临时目录，别动真的 /etc/apt
#   ENV_CODENAME    发行版代号 —— 不设就从 /etc/os-release 读
env_say()  { printf 'wtool-install: %s\n' "$*"; }
env_warn() { printf 'wtool-install: 警告: %s\n' "$*" >&2; }

# root 下不能带 sudo —— 最小化容器里根本没有 sudo，
# 写了的话用户照着复制会得到 "sudo: command not found"
env_priv() {
    if [ "$(id -u 2>/dev/null || echo 0)" = 0 ]; then printf ''
    elif command -v sudo >/dev/null 2>&1; then printf 'sudo '
    else printf ''
    fi
}

# 当前这台机器上"能不能提权"的四种情况（用户 2026-10-04 要求：
# **没有免密、甚至没有 sudo 的人也要能用 wtool**）：
#
#   root      本来就是 root                        → 直接用
#   nopass    sudo 免密（`sudo -n true` 成立）      → 直接用，不打扰
#   askpass   有 sudo，但要密码                    → **明确问一次**：说清要跑什么命令，
#                                                    让用户决定给不给密码
#   nosudo    根本没有 sudo（公司机器常见）        → **不做要 root 的事**，
#                                                    只装 wtool 自己（那部分不需要 root）
#
# 分类结果放 $ENV_PRIV / $ENV_PRIV_MODE。`sudo -n` 这个前缀很重要：
# 它保证装包过程中**绝不会**突然弹一个密码提示把脚本挂住。
# **这条规则和引擎那边的 `wtool_plan.py: sudo_state()` 必须一致**
# （两处实现、一个测试守着 —— 见 ADR-0035）：
#   root / nopass / askpass / none
env_sudo_state() {
    if [ "$(id -u 2>/dev/null || echo 0)" = 0 ]; then printf 'root'; return 0; fi
    case ${WTOOL_SUDO:-auto} in
        never|no|off) printf 'none'; return 0 ;;
        yes|always|force|on) printf 'nopass'; return 0 ;;
    esac
    command -v sudo >/dev/null 2>&1 || { printf 'none'; return 0; }
    if sudo -n true 2>/dev/null; then printf 'nopass'; return 0; fi
    # `sudo -n -l` 不弹提示：能列出规则 = 这个用户在 sudoers 里（只是要密码）
    if sudo -n -l >/dev/null 2>&1; then printf 'askpass'; return 0; fi
    printf 'none'
}

env_priv_refresh() {
    case $(env_sudo_state) in
        root)    ENV_PRIV="";          ENV_PRIV_MODE=root ;;
        nopass)  ENV_PRIV="sudo -n ";  ENV_PRIV_MODE=nopass ;;
        askpass) ENV_PRIV="";          ENV_PRIV_MODE=askpass ;;
        *)       ENV_PRIV="";          ENV_PRIV_MODE=nosudo ;;
    esac
    export ENV_PRIV ENV_PRIV_MODE
}

# 要 root 的时候调一次：能提权返回 0，提不了返回 1（调用方自己决定怎么退）
env_priv_ask() {   # <要做的事，用来告诉用户>
    _pa_why=${1:-要装几个系统包}
    # 没分类过就先分类（调用方忘了 env_priv_refresh 时也不会静默什么都不做）
    [ -n "${ENV_PRIV_MODE:-}" ] || env_priv_refresh
    case ${ENV_PRIV_MODE:-} in
        root|nopass) return 0 ;;
        nosudo)
            env_warn "  没有 sudo，跳过要 root 的部分（$_pa_why）"
            return 1 ;;
        askpass)
            env_say "  接下来要 root 权限：$_pa_why"
            env_say "  会执行：sudo apt-get update && sudo apt-get install ..."
            if [ ! -t 0 ]; then
                env_warn "  这里没有终端可以问密码 —— 跳过要 root 的部分"
                ENV_PRIV_MODE=nosudo
                export ENV_PRIV_MODE
                return 1
            fi
            printf '  请输入你的密码（只交给 sudo；直接回车 = 跳过，wtool 仍会装不需要 root 的部分）：' >&2
            stty -echo 2>/dev/null || true
            IFS= read -r _pa_pw || _pa_pw=""
            stty echo 2>/dev/null || true
            printf '\n' >&2
            if [ -z "$_pa_pw" ]; then
                env_warn "  没输密码 —— 跳过要 root 的部分"
                ENV_PRIV_MODE=nosudo
                export ENV_PRIV_MODE
                return 1
            fi
            if printf '%s\n' "$_pa_pw" | sudo -S -p '' -v 2>/dev/null; then
                _pa_pw=""   # 用完就丢，别留在变量里
                ENV_PRIV="sudo -n "; ENV_PRIV_MODE=nopass
                ENV_PRIV_CACHED=1
                export ENV_PRIV ENV_PRIV_MODE ENV_PRIV_CACHED
                env_say "  密码对，sudo 凭证已缓存（装完会 sudo -k 清掉）"
                return 0
            fi
            _pa_pw=""
            env_warn "  密码不对（或者这个用户其实没有 sudo 权限）—— 跳过要 root 的部分"
            ENV_PRIV_MODE=nosudo
            export ENV_PRIV_MODE
            return 1 ;;
        *) return 1 ;;
    esac
}

# 用完把缓存的 sudo 凭证清掉（用了密码那条路才需要）
env_priv_done() {
    [ "${ENV_PRIV_MODE:-}" = nopass ] || return 0
    [ "${ENV_PRIV_CACHED:-}" = 1 ] || return 0
    sudo -k 2>/dev/null || true
}

# ── 提权：普通用户跑 ./install.sh 时，apt 和 /etc/apt 的写都要 sudo ──────
#
# 2026-10-04 发现：这套脚本原来**只在 root 下能用** —— `env_prepare` 里算出了
# 提权前缀 `_p` 却没人用它，所有 `apt-get` 都是裸调的。在 root 的机器上
# （作者的 WSL）一直没暴露；容器里 `container-raw.sh --user` 建出普通用户之后，
# `./install.sh` 第一步就 permission denied。
#
# 规矩：**apt / /etc/apt 一律走下面这几个助手**，它们按 $ENV_PRIV 自动加 sudo：
#   ENV_PRIV=""       （root，或者根本没有 sudo 可用）
#   ENV_PRIV="sudo "  （普通用户 + 有 sudo）
env_priv_mkdir() { ${ENV_PRIV:-}mkdir -p "$@" 2>/dev/null || true; }
env_priv_rm()    { ${ENV_PRIV:-}rm -f -- "$@" 2>/dev/null || true; }
env_priv_cp()    { ${ENV_PRIV:-}cp -a -- "$@" 2>/dev/null || true; }
env_priv_write() {   # <目标文件>，内容走 stdin
    _pw_dst=$1
    if [ -n "${ENV_PRIV:-}" ]; then
        ${ENV_PRIV}tee "$_pw_dst" >/dev/null
    else
        cat > "$_pw_dst"
    fi
}

env_need_root() {
    [ "$(id -u 2>/dev/null || echo 1)" = 0 ] && return 0
    command -v sudo >/dev/null 2>&1 && return 0
    env_warn "当前既不是 root 也没有 sudo，装包这一步会失败"
    env_warn "  手动执行时加 sudo，或者用 root 跑"
    return 1
}

# 换源：可选。不设 ENV_MIRROR 就完全不动系统源。
#
# 默认**不动**是有道理的：能连通官方源的机器不该被我们改掉配置，
# 而且改源是个有副作用的动作，用户没要求就不该做。
# 需要的时候（比如容器里走代理 502）用环境变量打开：
#     WTOOL_MIRROR=mirrors.ustc.edu.cn ./install.sh
env_use_mirror() {
    _um_host=${1:-${ENV_MIRROR:-}}
    [ -n "$_um_host" ] || return 0
    ENV_MIRROR=$_um_host
    env_say "换 apt 源 → $_um_host"
    # 先把**原来的**源文件备份一份：万一这个镜像不好用，得有路回去。
    # （以前是直接删掉原源 —— 换源失败就没退路了。）
    _um_dir=${ENV_APT_DIR:-/etc/apt}
    env_priv_refresh
    if [ ! -d "$_um_dir/wtool-sources.bak" ]; then
        env_priv_mkdir "$_um_dir/wtool-sources.bak"
        env_priv_cp "$_um_dir/sources.list" "$_um_dir/wtool-sources.bak/"
        env_priv_mkdir "$_um_dir/wtool-sources.bak/sources.list.d"
        env_priv_cp "$_um_dir/sources.list.d/." "$_um_dir/wtool-sources.bak/sources.list.d/"
    fi
    . /etc/os-release 2>/dev/null || true
    [ -n "${VERSION_CODENAME:-}" ] || { env_warn "读不出 VERSION_CODENAME，跳过换源"; return 0; }

    env_priv_mkdir "$_um_dir/sources.list.d"
    # deb822（.sources）在 apt 1.1 就有了，20.04 的 apt 2.0 也认。
    # 曾经误以为 focal 不认，走了弯路 —— 见 harness/docs/hazards.md。
    env_priv_write "$_um_dir/sources.list.d/wtool-mirror.sources" <<EOF
Types: deb
URIs: http://$ENV_MIRROR/ubuntu/
Suites: $VERSION_CODENAME $VERSION_CODENAME-updates $VERSION_CODENAME-backports $VERSION_CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    # 原来的源文件要清掉，否则它还指着官方源，换源等于没换。
    # 20.04 是 /etc/apt/sources.list，24.04 是 sources.list.d/ubuntu.sources —— 两种都清。
    env_priv_rm "$_um_dir/sources.list"
    for _f in "$_um_dir"/sources.list.d/*; do
        case $_f in
            */wtool-mirror.sources) ;;
            *) env_priv_rm "$_f" ;;
        esac
    done
}

# 把这次的选择记到状态目录：`<代号>\t<主机名|->\t<来源>\t<时间>`。
#
# 为什么记：**系统层也要换源**（项目清单里的
# `<sudo-install kind="apt-mirror" mirror="auto"/>`）。它得知道"这台机器上已经
# 换过了、换成哪个" —— 否则两处各写一份源文件，apt 会警告
# "Target Packages ... is configured multiple times"，装包任务会失败
# （2026-10-04 实测，见 harness/docs/hazards.md H20）。
# 引擎读的就是这个文件（`lib/wtool_plan.py` 的 `_recorded_mirror`）。
env_mirror_record() {   # <代号> [主机名]
    _mr_code=$1; _mr_host=${2:--}
    _mr_state=${WTOOL_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/wtool}
    mkdir -p "$_mr_state" 2>/dev/null || return 0
    # 来源默认写 install.sh；container-raw.sh --user 会把它设成自己的名字，
    # 这样 `mirror.txt` 里能看出"这台机器上是谁挑的"
    printf '%s\t%s\t%s\t%s\n' "$_mr_code" "$_mr_host" "${ENV_MIRROR_SOURCE:-install.sh}" \
        "$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || echo -)" \
        > "$_mr_state/mirror.txt" 2>/dev/null || true
}

# ── 镜像：测速 → 让用户挑（用户 2026-10-04 要求）──────────────────────
#
# 以前是"系统自带的源能用就不动它"。那条规矩来自一次教训（换源之后 apt 卡死
# 500 秒，而系统源 153 秒能跑完）—— **能跑通的路径不该为了"可能更快"去动它**。
# 但它有个前提：系统源和国内镜像**速度差不多**。实测不是这样（2026-10-04，
# 同一个文件 dists/noble/main/binary-amd64/Packages.gz 的 1.4 MB）：
#
#     mirrors.tuna.tsinghua.edu.cn   0.17s
#     mirrors.huaweicloud.com        0.25s
#     mirrors.aliyun.com             0.35s
#     mirrors.163.com                0.35s
#     mirrors.ustc.edu.cn            0.39s
#     archive.ubuntu.com（官方）      2.66s     ← 慢 15 倍
#
# 官方源那 2.66 秒摊到 python3+git+curl（几十 MB）上就是好几分钟，
# 用户在容器里就是这么被卡住的。所以现在**先测速、再让用户挑**，
# 但保留原来的教训：测不通/挑错了要有退路（见 env_apt_ready 的兜底）。

# 一行一个候选：<代号> <主机名> <给人看的名字>
# 代号就是 `WTOOL_MIRROR=<代号>` 能用的那个；主机名要能在 /ubuntu/ 下找到发行版目录。
env_mirror_list() {
    cat <<'EOF'
tuna mirrors.tuna.tsinghua.edu.cn 清华
huawei mirrors.huaweicloud.com 华为云
aliyun mirrors.aliyun.com 阿里云
netease mirrors.163.com 网易
ustc mirrors.ustc.edu.cn 中科大
tencent mirrors.cloud.tencent.com 腾讯云
official archive.ubuntu.com 官方
EOF
}

# 候选镜像里发行版目录叫什么：x86 是 ubuntu/，arm 那几家在 ubuntu-ports/
env_mirror_dir() {
    case ${WTOOL_ARCH:-$(uname -m 2>/dev/null || echo x86_64)} in
        aarch64|arm64|armv7l|armhf|riscv64) printf 'ubuntu-ports' ;;
        *) printf 'ubuntu' ;;
    esac
}

# 测一个镜像：下载它的 Packages.gz（约 1.4 MB），**最多 3 秒**。
# 打印 "<字节> <毫秒>"；连不上（一个字节都没下来）返回 1。
#
# 为什么用 /usr/lib/apt/apt-helper 而不是 curl：这一步**还没装 curl**
# （正在装的就是它）。apt-helper 是 apt 自带的，任何 Ubuntu 上都有；
# 而且它走的是 apt 自己的下载路径，量出来的速度就是 apt 装包时的速度。
# 为什么"3 秒掐断也能算速度"：慢镜像下不满 3 秒下的字节数/用时就是它的真实速率；
# 快镜像会在 3 秒内下完，那个数就是它的真实速率。两边都可比。
env_mirror_probe() {   # <主机名> <发行版代号>
    _pb_host=$1; _pb_code=$2
    _pb_dir=$(env_mirror_dir)
    _pb_url="http://$_pb_host/$_pb_dir/dists/$_pb_code/main/binary-amd64/Packages.gz"
    _pb_helper=${ENV_APT_HELPER:-/usr/lib/apt/apt-helper}
    _pb_out=/tmp/wtool-mirror-probe.$$
    rm -f -- "$_pb_out" 2>/dev/null || true
    _pb_t0=$(date +%s%N 2>/dev/null || echo 0)
    # DIRECT：测的就是"直连这个镜像"——换源之后 apt 也是直连（见 env_apt_bypass_proxy）。
    # 走代理测会把代理的速度算到镜像头上，选出来的"最快"就是假的。
    timeout 3 "$_pb_helper" download-file \
        -o "Acquire::http::Proxy::$_pb_host=DIRECT" \
        "$_pb_url" "$_pb_out" >/dev/null 2>&1 || true
    _pb_t1=$(date +%s%N 2>/dev/null || echo 0)
    _pb_bytes=$(stat -c%s "$_pb_out" 2>/dev/null || echo 0)
    rm -f -- "$_pb_out" 2>/dev/null || true
    _pb_ms=$(( (_pb_t1 - _pb_t0) / 1000000 ))
    [ "${_pb_ms:-0}" -gt 0 ] || _pb_ms=1
    [ "${_pb_bytes:-0}" -gt 0 ] || return 1
    printf '%s %s\n' "$_pb_bytes" "$_pb_ms"
}

# 把 "<字节> <毫秒>" 说成人话：6.83 MB/s / 171 KB/s
env_mirror_rate() {   # <字节> <毫秒>
    _rt_kbps=$(( $1 / $2 ))          # 字节/毫秒 == KB/s
    if [ "$_rt_kbps" -ge 1024 ]; then
        printf '%d.%02d MB/s' "$((_rt_kbps / 1024))" "$(( (_rt_kbps % 1024) * 100 / 1024 ))"
    elif [ "$_rt_kbps" -ge 1 ]; then
        printf '%d KB/s' "$_rt_kbps"
    else
        printf '%d B/s' "$(( $1 * 1000 / $2 ))"
    fi
}

env_mirror_secs() {   # <毫秒>
    printf '%d.%02ds' "$(( $1 / 1000 ))" "$(( ($1 % 1000) / 10 ))"
}

# 测速 → 画表 → 问用户 → 打印选中的 "<代号> <主机名>"
#
# 非交互（没有终端可问）时**自动选最快的**并说明 —— 脚本里跑的命令绝不该卡在等输入上
# （和 publish-release 那条规矩一致）。
env_mirror_pick() {
    . /etc/os-release 2>/dev/null || true
    _pk_code=${ENV_CODENAME:-${VERSION_CODENAME:-}}
    [ -n "$_pk_code" ] || { env_warn "读不出 VERSION_CODENAME，跳过测速"; return 1; }

    # 这一段全是**给人看的**：表格、提示、问话都走 stderr。
    # 为什么：函数用 stdout 返回"选中的镜像"，调用方是 `$(...)` 捕获 ——
    # 提示打到 stdout 就会被当成返回值（实测把 "wtool-install:" 当成了代号）。
    env_say "  测速（各站点直连取 dists/$_pk_code/main/binary-amd64/Packages.gz，最多 3 秒）" >&2
    _pk_tmp=$(mktemp 2>/dev/null || echo /tmp/wtool-mirror.$$)
    : > "$_pk_tmp"
    _pk_i=0
    env_mirror_list | while read -r _c _h _n; do
        [ -n "${_h:-}" ] || continue
        _pk_i=$((_pk_i + 1))
        if _r=$(env_mirror_probe "$_h" "$_pk_code"); then
            printf '%s\t%s\t%s\t%s\t%s\n' "$_pk_i" "$_c" "$_h" "$_n" "$_r" >> "$_pk_tmp"
        else
            printf '%s\t%s\t%s\t%s\t-\n' "$_pk_i" "$_c" "$_h" "$_n" >> "$_pk_tmp"
        fi
    done

    # 按速度排（失败的排最后），最快的在第一行。
    # ⚠️ 这里踩过一次：一开始写的是"把速度取负、再按字符串升序" ——
    #    `-0000000000005240.0000` 和 `-0000000000000080.0000` 按**字符串**比，
    #    慢的那个反而排在前面（负号后第一位 '0' < '5'），于是表里最慢的成了 #1、
    #    默认选项就是官方源。改成 `sort -rn` 按数值降序，别再自己造排序。
    _pk_sorted=$(mktemp 2>/dev/null || echo /tmp/wtool-mirror-s.$$)
    awk -F'\t' '{
        if ($5 == "-") { kbps = -1 }
        else { split($5, a, " "); kbps = a[1] / a[2] }
        printf "%.4f\t%s\n", kbps, $0
    }' "$_pk_tmp" | LC_ALL=C sort -rn | cut -f2- > "$_pk_sorted"

    # 画表（宽度写死，数据行都是 ASCII，不存在 CJK 对不齐的问题）
    # 宽度写死；数据行必须是**纯 ASCII** —— printf 的 %-10s 按字节补空格，
    # 中文（如"连不上"）会算错宽度，表格立刻歪（实测过）。
    printf '  ┌────┬──────────────────────────────┬────────────┬────────┐\n' >&2
    printf '  │  # │ 镜像                         │ 速度       │ 用时   │\n' >&2
    printf '  ├────┼──────────────────────────────┼────────────┼────────┤\n' >&2
    _pk_n=0
    while IFS='	' read -r _i _c _h _n _r; do
        [ -n "${_h:-}" ] || continue
        _pk_n=$((_pk_n + 1))
        if [ "$_r" = "-" ]; then
            printf '  │ %2s │ %-28s │ %-10s │ %-6s │\n' "$_pk_n" "$_h" "n/a" "-" >&2
        else
            _b=${_r%% *}; _ms=${_r##* }
            printf '  │ %2s │ %-28s │ %-10s │ %-6s │\n' "$_pk_n" "$_h" \
                "$(env_mirror_rate "$_b" "$_ms")" "$(env_mirror_secs "$_ms")" >&2
        fi
    done < "$_pk_sorted"
    printf '  └────┴──────────────────────────────┴────────────┴────────┘\n' >&2

    _pk_first=$(sed -n '1p' "$_pk_sorted")
    _pk_first_host=$(printf '%s\n' "$_pk_first" | cut -f3)
    _pk_first_code=$(printf '%s\n' "$_pk_first" | cut -f2)
    _pk_first_rate=$(printf '%s\n' "$_pk_first" | cut -f5)
    if [ "$_pk_first_rate" = "-" ]; then
        rm -f -- "$_pk_tmp" "$_pk_sorted"
        env_warn "  所有镜像都连不上（是不是要走代理？）—— 保持系统自带的源"
        return 1
    fi

    _pk_choice=""
    if [ -t 0 ]; then
        printf '  选一个 [1-%s]（回车 = 1，最快的是 %s）：' "$_pk_n" "$_pk_first_host" >&2
        _pk_try=0
        while [ "$_pk_try" -lt 3 ]; do
            _pk_try=$((_pk_try + 1))
            read -r _ans || _ans=""
            case $_ans in
                "") _pk_choice="1"; break ;;
                *[!0-9]*) printf '  请输入 1-%s 之间的数字：' "$_pk_n" >&2 ;;
                *) if [ "$_ans" -ge 1 ] && [ "$_ans" -le "$_pk_n" ]; then _pk_choice=$_ans; break
                   else printf '  请输入 1-%s 之间的数字：' "$_pk_n" >&2; fi ;;
            esac
        done
        [ -n "$_pk_choice" ] || { _pk_choice=1; env_warn "  没选，用最快的那个"; }
    else
        _pk_choice=1
        env_say "  非交互环境：自动选最快的 #1（$_pk_first_host）" >&2
    fi

    _pk_row=$(sed -n "${_pk_choice}p" "$_pk_sorted")
    rm -f -- "$_pk_tmp" "$_pk_sorted"
    printf '%s %s\n' "$(printf '%s' "$_pk_row" | cut -f2)" "$(printf '%s' "$_pk_row" | cut -f3)"
    return 0
}

# 挑一个能用的 apt 源。先试系统自带的，实在不行再换国内镜像。
env_apt_ready() {
    env_say "检查 apt 源"

    # ── 这台机器上已经挑过一次了 → 接着用，不再测速 ──────────────────
    #
    # 记录在 <state>/mirror.txt（install.sh 第 0 步写的，引擎的系统层也读它，
    # 见 ADR-0032）。第二次跑 install.sh 时**没必要再测一遍**：
    # 测速要下 7 个索引（每个最多 3 秒），而结果十有八九还是同一个。
    #
    # 想重挑：WTOOL_MIRROR=pick（或者 auto/test），或者直接给代号/主机名。
    case ${WTOOL_MIRROR:-} in
        pick|auto|test) WTOOL_MIRROR="" ;;   # 强制重新测速
    esac
    if [ -z "${WTOOL_MIRROR:-}" ]; then
        _rr_state=${WTOOL_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/wtool}
        if [ -s "$_rr_state/mirror.txt" ]; then
            _rr_code=$(cut -f1 "$_rr_state/mirror.txt" 2>/dev/null | head -1)
            _rr_host=$(cut -f2 "$_rr_state/mirror.txt" 2>/dev/null | head -1)
            if [ "$_rr_code" = "official" ]; then
                env_say "  上次（$_rr_state/mirror.txt）选的是官方源 → 接着用，不再测速"
                env_apt_try 2 ${ENV_PRIV:-}apt-get update -qq >/dev/null 2>&1 || true
                return 0
            fi
            if [ -n "$_rr_host" ] && [ "$_rr_host" != "-" ]; then
                env_say "  上次挑的是 $_rr_host（$_rr_code）→ 接着用"
                env_say "  想重新测速：WTOOL_MIRROR=pick ./install.sh"
                env_apt_bypass_proxy "$_rr_host"
                env_use_mirror "$_rr_host"
                env_apt_try 2 ${ENV_PRIV:-}apt-get update -qq >/dev/null 2>&1                     || env_warn "  它现在更新不了 —— 想重挑就 WTOOL_MIRROR=pick ./install.sh"
                return 0
            fi
        fi
    fi

    # ── 用户显式指定：不测速，直接用 ────────────────────────────────
    #   WTOOL_MIRROR=ustc        按代号（见 env_mirror_list）
    #   WTOOL_MIRROR=mirrors.aliyun.com   直接给主机名
    #   WTOOL_MIRROR=official    保持系统自带的源（不换）
    if [ -n "${WTOOL_MIRROR:-}" ]; then
        case $WTOOL_MIRROR in
            official|system|no|off|"")
                # ⚠️ 这里必须 return —— 少写一个 return 就会**继续往下走**
                # 去测速、然后把用户明确要用的系统源换掉（测试抓到过：
                # "official = 不换源" 通过了，但它其实换了，只是没打印）
                env_say "  按 WTOOL_MIRROR=$WTOOL_MIRROR：保持系统自带的源"
                env_mirror_record official
                env_apt_try 2 ${ENV_PRIV:-}apt-get update -qq >/dev/null 2>&1 \
                    || env_warn "  系统自带的源更新不了 —— 网络问题，下面的装包大概率会失败"
                return 0 ;;
            *)
                _wm_host=$WTOOL_MIRROR
                case $WTOOL_MIRROR in
                    *.*) ;;   # 已经是主机名
                    *) _wm_host=$(env_mirror_list | awk -v c="$WTOOL_MIRROR" '$1 == c {print $2; exit}') ;;
                esac
                if [ -n "$_wm_host" ]; then
                    env_say "  按 WTOOL_MIRROR 指定：$_wm_host"
                    env_mirror_record "${WTOOL_MIRROR}" "$_wm_host"
                    env_apt_bypass_proxy "$_wm_host"
                    env_use_mirror "$_wm_host"
                    if env_apt_try 2 ${ENV_PRIV:-}apt-get update -qq >/dev/null 2>&1; then
                        env_say "  换源后可用"
                    else
                        env_warn "  指定的源不好用，放回原来的源"
                        env_apt_restore_sources
                        env_apt_try 2 ${ENV_PRIV:-}apt-get update -qq >/dev/null 2>&1 || true
                    fi
                    return 0
                fi
                env_warn "  WTOOL_MIRROR=$WTOOL_MIRROR 不认识（用代号或主机名），改成测速" ;;
        esac
    fi

    # ── 测速 → 让用户挑（用户 2026-10-04 要求）─────────────────────
    #
    # 为什么不"系统源能用就先用"：能用 ≠ 快。实测官方源比国内镜像慢 15 倍
    # （同一个 1.4 MB 的文件：官方 2.66s，清华 0.17s），而这一步要装
    # python3 + git + curl 几十 MB —— 差的就是好几分钟。
    #
    # ⚠️ 保留上一版的教训：**换源是"可能卡死"的那条路**（曾经 500 秒没动静），
    # 所以这里三道保险：① 只在测速有结果时才换 ② 换完 apt-get update 不过就
    # ③ 把原源放回去。任何一道失败都退回"系统自带的源"。
    _picked=$(env_mirror_pick) || _picked=""
    _pick_code=${_picked%% *}
    _pick_host=${_picked##* }
    if [ -z "$_pick_code" ] || [ "$_pick_code" = "official" ]; then
        env_say "  用系统自带的源"
        env_mirror_record official
        env_apt_try 2 ${ENV_PRIV:-}apt-get update -qq >/dev/null 2>&1 \
            || env_warn "  系统自带的源更新不了 —— 网络问题，下面的装包大概率会失败"
        return 0
    fi

    env_say "  用 $_pick_host（$_pick_code）"
    env_mirror_record "$_pick_code" "$_pick_host"
    # 关键：换源之后**不要让 apt 再走代理**。容器里 HTTP_PROXY 是设着的
    # （container-proxy.sh 接的宿主代理），apt 默认对所有 http 都走它 ——
    # 于是"换国内镜像"只是换了个域名，路还是同一条。国内镜像直连最快。
    # 测速那一步量的也是直连（DIRECT），这里对得上。
    env_apt_bypass_proxy "$_pick_host"
    env_use_mirror "$_pick_host"
    if env_apt_try 2 ${ENV_PRIV:-}apt-get update -qq >/dev/null 2>&1; then
        env_say "  换源后可用"
        return 0
    fi

    # 挑的那个不好用 → 退回原来的源（这才是"能用就别乱动"那句话真正要的保护）
    env_warn "  $_pick_host 更新不了，把原来的源放回去"
    env_apt_restore_sources
    if env_apt_try 2 ${ENV_PRIV:-}apt-get update -qq >/dev/null 2>&1; then
        env_say "  原来的源可用"
    else
        env_warn "  两条路都不行 —— 网络问题，下面的装包大概率会失败"
    fi
}

# 换源失败时的退路：把备份的原源放回去。
env_apt_restore_sources() {
    _rs_dir=${ENV_APT_DIR:-/etc/apt}
    [ -d "$_rs_dir/wtool-sources.bak" ] || return 0
    for _f in "$_rs_dir"/sources.list.d/*; do
        case $_f in
            */wtool-mirror.sources) rm -f -- "$_f" 2>/dev/null || true ;;
        esac
    done
    env_priv_cp "$_rs_dir/wtool-sources.bak/sources.list" "$_rs_dir/sources.list"
    env_priv_cp "$_rs_dir/wtool-sources.bak/sources.list.d/." "$_rs_dir/sources.list.d/"
    env_say "  已把原来的 apt 源放回去"
}

# 让 apt 访问某个主机时**不走代理**。
#
# env 里的 no_proxy 各版本 apt 处理不一致，所以除了环境变量，
# 再写一条 apt 自己的配置（双保险）。
env_apt_bypass_proxy() {
    _h=$1
    [ -n "$_h" ] || return 0
    for _v in no_proxy NO_PROXY; do
        eval "_cur=\${$_v:-}"
        case ",$_cur," in
            *",$_h,"*) ;;
            *) export "$_v=${_cur:+$_cur,}$_h" ;;
        esac
    done
    env_priv_refresh
    env_priv_mkdir "${ENV_APT_DIR:-/etc/apt}/apt.conf.d" || return 0
    printf 'Acquire::http::Proxy::%s "DIRECT";\n' "$_h" \
        | env_priv_write "${ENV_APT_DIR:-/etc/apt}/apt.conf.d/99wtool-noproxy"
}

# 装一个包，**按候选名依次试**。
#
# 为什么需要"依次试"：包名在发行版之间会变。同一个东西：
#   Ubuntu 22.04+   ansible-core
#   Ubuntu 20.04    只有 ansible（2.9），**没有 ansible-core**
# 写死一个名字，在另一种系统上就是 "Unable to locate package"，
# 然后用户得自己去猜该装什么 —— 而这时候源已经配好了，我们完全有能力自己试出来。
env_install_first() {
    _desc=$1; shift
    # 循环变量**必须用这个名字**，不能叫 _p ——
    # 调用方的 env_prepare 里 _p 存着"提权前缀"（空或 "sudo "），
    # 被这里覆盖之后，后面那句提示就成了
    #     "请手动装：ansibleapt-get install -y git"
    # 这种"看着像乱码"的输出，根源都是变量被别的函数偷了。
    env_priv_refresh
    for _cand in "$@"; do
        # shellcheck disable=SC2086
        if DEBIAN_FRONTEND=noninteractive env_apt_try 3 \
               ${ENV_PRIV:-}apt-get install -y -q --no-install-recommends $_cand; then
            env_say "  $_desc ✓（包名 $_cand）"
            return 0
        fi
    done
    env_warn "  $_desc 装不上（试过: $*）"
    return 1
}

# apt 拿不到锁时**等一等再试**，并把话说清楚。
#
# 为什么不是"加个 apt 选项就完事"：`DPkg::Lock::Timeout` 只管 dpkg 的
# frontend 锁，**不管** `/var/cache/apt/archives/lock`。2026-09-29 实测
# （apt 2.4.14，ubuntu 22.04 容器）：
#
#     另一个进程拿住 archives 锁，apt-get install 报
#       E: Could not get lock /var/cache/apt/archives/lock. It is held by process 9 (python3)
#     不带选项：立刻失败；带 -o DPkg::Lock::Timeout=4：**照样 1.4 秒就失败**。
#
# 而这把锁最容易在**两个容器共用 `/var/cache/apt` 卷**时被抢 ——
# 那时报错里的 pid 会变成 0（占用者在另一个 PID 命名空间里，apt 认不出是谁），
# 正是用户 2026-10-04 在 Docker Desktop 上撞到的那个
# `It is held by process 0`。所以这里只能自己重试，并把"去看谁在跑"教给用户。
env_apt_lock_hint() {
    env_warn "  apt 的锁被占着 —— 多半是**另一个容器**在共用 /var/cache/apt（或它在跑 apt）"
    env_warn "    看谁在跑：docker ps        （同一个卷挂到两个容器时，两边不能同时 apt）"
    env_warn "    确认没有活着的 apt 之后，才是清的（apt 自己那句『别删锁文件』是针对活锁说的）："
    env_warn "      rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock"
}

# 跑一条 apt 命令，锁被占着就等一会儿重试（最多 <次数> 次）
env_apt_try() {   # <次数> <命令...>
    _at_n=$1; shift
    _at_i=0
    _at_out=$(mktemp 2>/dev/null || echo /tmp/wtool-apt.$$)
    while :; do
        _at_i=$((_at_i + 1))
        # 后台跑 + 每 5 秒报一次"还在装"，顺手把 apt 最后一行贴出来。
        # 为什么要这个心跳：apt 的输出被重定向进文件（要拿它判断"是不是在等锁"），
        # 于是下载几十 MB 的那几分钟里**屏幕上什么都没有** —— 用户看到的现象
        # 就是"卡住"（实测：11 MB/s 下着，人以为死了，把容器 Ctrl-C 了）。
        "$@" >"$_at_out" 2>&1 &
        _at_pid=$!
        _at_ticks=0
        while kill -0 "$_at_pid" 2>/dev/null; do
            sleep 5
            kill -0 "$_at_pid" 2>/dev/null || break
            _at_ticks=$((_at_ticks + 5))
            _at_last=$(tail -1 "$_at_out" 2>/dev/null | tr -d '\r' | cut -c1-70)
            env_say "    还在装…（$_at_ticks 秒）${_at_last:+  · $_at_last}"
        done
        _at_rc=0
        wait "$_at_pid" || _at_rc=$?
        if [ "$_at_rc" = 0 ]; then
            rm -f "$_at_out"
            return 0
        fi
        if grep -q 'Could not get lock\|Unable to lock' "$_at_out" 2>/dev/null; then
            if [ "$_at_i" -ge "$_at_n" ]; then
                env_apt_lock_hint
                sed 's/^/    /' "$_at_out" >&2
                rm -f "$_at_out"
                return 1
            fi
            env_warn "  apt 在等锁（第 $_at_i 次拿不到）—— 5 秒后再试"
            sleep 5
            continue
        fi
        sed 's/^/    /' "$_at_out" >&2
        rm -f "$_at_out"
        return 1
    done
}

# ── 主流程 ──
# 让 apt 快速失败。
#
# **apt 默认没有下载超时**：连接一停滞，它就永远等下去，
# 表现是"脚本卡住了"，而人第一反应是去查网络 —— 查不出所以然。
# 在 astronvim 的 build.sh 里踩过一次（卡了 20 分钟、partial/ 一个字节都没有），
# 这里是同一个坑的另一个入口。
#
# 加上超时之后，"停滞"会变成"失败"，重试/换源才有机会生效。
env_apt_fastfail() {
    env_priv_refresh
    env_priv_mkdir /etc/apt/apt.conf.d || return 0
    env_priv_write /etc/apt/apt.conf.d/99wtool-timeout <<'EOF'
Acquire::http::Timeout "20";
Acquire::https::Timeout "20";
Acquire::Retries "3";
EOF
}

env_prepare() {
    env_say "系统：$ENV_NAME"
    command -v apt-get >/dev/null 2>&1 \
        || { env_warn "这个脚本只处理 apt 系发行版；请手动装 python3 / git / curl / ca-certificates"; return 1; }

    # ── 先判断这台机器上"要不要 root、能不能拿到 root" ──────────────────
    # 用户 2026-10-04 的要求：**没有免密、甚至没有 sudo 的人也要能用 wtool**。
    # 公司机器上通常就是这种：python3 / git 早就有了，装 wtool 自己
    # （自举引擎 + 写 ~/.wtool + 建符号链接）**一个 root 都不需要**。
    env_priv_refresh
    _miss=""
    for _c in python3 git curl; do
        command -v "$_c" >/dev/null 2>&1 || _miss="$_miss $_c"
    done

    if [ -z "$_miss" ]; then
        env_say "  运行环境已经在（python3 / git / curl 都有）—— 不需要 root"
        ENV_SKIP_APT=1
    else
        env_say "  缺这些命令：$_miss"
        if env_priv_ask "装这几个包：$_miss（另外还有 ca-certificates 和 ansible）"; then
            env_apt_fastfail
            env_apt_ready
            env_say "装 wtool 需要的运行环境"
            _try=0
            while [ "$_try" -lt 2 ]; do
                _try=$((_try + 1))
                # shellcheck disable=SC2086
                if DEBIAN_FRONTEND=noninteractive env_apt_try 3 \
                       ${ENV_PRIV:-}apt-get install -y -q --no-install-recommends \
                       ca-certificates git python3 curl ${ENV_EXTRA_PKGS:-}; then
                    env_say "  ca-certificates git python3 curl ✓"
                    break
                fi
                [ "$_try" -ge 2 ] && env_warn "  基础包装了两遍还是没全装上，看下面缺什么"
                sleep 3
            done
            # ansible 是可选的：只有 os/ubuntu 的 provision 用它。
            # 装不上不影响 wtool 本体，所以失败只警告。
            env_say "  顺手装 ansible（os/ubuntu 的系统层要用；几十 MB，不要它也可以先 Ctrl-C）"
            env_install_first "ansible（os/ubuntu 装系统包用）" $ENV_ANSIBLE || true
        else
            # 拿不到 root：把该说的话说全，然后**只做不需要 root 的部分**
            env_warn "  跳过要 root 的那部分。你可以让管理员（或用自己别的路子）装："
            env_warn "    apt-get update && apt-get install -y$_miss ca-certificates"
            env_warn "  wtool 自己（引擎 + ~/.wtool + 软链）**不需要 root**，下面照装。"
            env_warn "  将来要跑系统层（wtool sudo-bootstrap）时再要 root 也不迟。"
        fi
    fi

    # 装完复查，缺什么明说 —— 不要让用户在后面某一步才撞上
    _miss2=""
    for c in python3 git; do command -v "$c" >/dev/null 2>&1 || _miss2="$_miss2 $c"; done
    if [ -n "$_miss2" ]; then
        env_warn "还缺:$_miss2 —— wtool 跑不起来（规划器要 python3，读仓库要 git）"
        env_warn "  请先装上它们（管理员 / 自己装 / 换个有这些包的机器），再跑一次 ./install.sh"
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        env_warn "  没有 curl —— wtool 本体能用，但 download-release / publish-release 会失败"
    fi

    # 最后一件：让 git 接受这个仓库。
    #
    # 容器里以 root 访问宿主目录时，git 会以 "dubious ownership" 拒绝工作；
    # 普通用户 uid 和宿主不一致时同样。这是**环境**问题不是项目问题，
    # 所以在这里解决掉 —— 否则用户会在下一步撞上一句看起来和"装 wtool"
    # 毫不相干的 git 报错，然后去怀疑网络、怀疑仓库坏了。
    # **必须放在装 git 之后**：git 还没装上时这条命令根本不存在。
    env_git_ownership

    env_priv_done   # 用了密码那条路的话，把缓存的 sudo 凭证清掉
    env_say "运行环境就绪"
}

# 让 git 认挂进来的仓库。
#
# 触发它的有两种情况，**都不是"以 root 才行"**：
#   · 容器里以 root 访问宿主目录（uid 0 ≠ 宿主 uid）
#   · 容器里的普通用户 uid 和宿主 uid 不一样（`container-raw.sh --user`
#     在镜像自带的 uid 1000 被 `ubuntu` 占着时会拿到 1001 —— 实测就是这么撞上的：
#     `wtool install` 报 "git 拒绝使用 /wtool/bootstrap 的仓库"）
# 所以这里**不再限定 root**：谁跑 install.sh 就给谁设。
env_git_ownership() {
    [ -n "${WTOOL_WS_DIR:-}" ] || return 0
    command -v git >/dev/null 2>&1 || return 0
    # ⚠️ 别拿**工作区根目录**去试：它是 repo 客户端，**不是 git 仓库**
    #    （`git -C /wtool rev-parse` 必然失败）。要试就试里面某个项目。
    _go_probe=""
    for _go_cand in "$WTOOL_WS_DIR/bootstrap" "$WTOOL_WS_DIR"/*/; do
        [ -d "$_go_cand/.git" ] || [ -f "$_go_cand/.git" ] || continue
        _go_probe=$_go_cand
        break
    done
    [ -n "$_go_probe" ] || return 0
    # 读一次试试：能读就什么都不用做
    if git -C "$_go_probe" rev-parse --git-dir >/dev/null 2>&1; then
        return 0
    fi
    git config --global --add safe.directory '*' 2>/dev/null || true
    if git -C "$_go_probe" rev-parse --git-dir >/dev/null 2>&1; then
        env_say "  已允许 git 使用挂载进来的仓库（uid 和宿主不一致时要这一步）"
    else
        env_warn "  git 还是读不了 $_go_probe —— 手动跑一次：git config --global --add safe.directory '*'"
    fi
}
