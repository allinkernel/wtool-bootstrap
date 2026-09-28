#!/bin/sh
# wtool —— wtool 集合的引擎（唯一一份，住在 wtool-bootstrap 里）
#
#   ── 日常三条 ───────────────────────────────────────────────
#   wtool sudo-install <项目>... [--dry-run] [--force]
#                      系统层：/etc 下的文件 + 要跑的脚本/playbook + apt 包。
#                      **可能要 sudo、要联网**；和 install 永不互相调用
#   wtool install      <项目目录> [--dry-run] [--force] [--no-script]
#                      用户层：项目 install.sh（output/ → ~/.wtool）→
#                      wtool.xml 的 link（影子 HOME → $HOME）。**永不 sudo、永不联网**
#   wtool uninstall    <项目目录>|--id <id> [--dry-run] [--force] [--no-script]
#                      撤销上一条（不还原 /etc —— 那是 sudo-uninstall 的事）
#
#   ── 系统层 ─────────────────────────────────────────────────
#   wtool sudo-uninstall <项目>...|all    撤系统层：/etc 还原 + 卸掉这次装的 apt 包
#   wtool sudo-bootstrap [--dry-run]      所有项目的 sudo-install
#
#   ── 产物与发布 ─────────────────────────────────────────────
#   wtool build     [<项目>...|all] [--dry-run]   跑项目自己的 scripts/build.sh
#   wtool download-release [<项目>...|all] [--dry-run]
#                       读**项目里提交的** scripts/release.json → 下到 <项目>/release/
#                       只下载 + 校验，**不解包**（解包是 unpack-release）
#   wtool pack-release   <项目>... [--tag=T] [--repo=owner/repo] [--volume-size=32M]
#                       打包到 <项目>/release/：源码.zip、release.zip（大的切分卷）、
#                       dist.json、两个 -hash.txt、.source 来源标记，
#                       另写 docs/download.md
#   wtool unpack-release <项目>... [--from=目录]
#                       照 dist.json 校验每卷 sha256 → 拼接 → 解到 output/
#   wtool publish-release [<项目>...] [--tag=TAG] [--dry-run] [--force]
#                       把 <项目>/release/ 里的东西传到 GitHub Release（**只上传**），
#                       成功之后写 scripts/release.json（下载清单，记得提交）
#   wtool layer-save     <项目> --image=<镜像> [--target=] [--layer=]
#                       docker 镜像 → <项目>/layer/<target>/（OCI 布局，blob 按 sha256 去重）
#   wtool layer-load     <项目> [--target=]
#                       <项目>/layer/<target>/ → docker（接着构建 / 恢复容器用）
#   wtool unpack-layer   <项目> [--layer=] [--target=]
#                       layer/<target>/ 的顶层 blob → output/<target>/<层>/。**不联网、不要 docker**
#   wtool push-layer     <项目>... [--registry=<前缀>] [--target=] [--layer=]
#                       layer/<target>/ 的层镜像 → 镜像仓库（docker push）
#   wtool pull-layer     <项目>... [--registry=<前缀>] [--target=] [--layer=]
#                       镜像仓库 → layer/<target>/（**目标机不需要 docker**）
#
#   ── 一次装好 ───────────────────────────────────────────────
#   wtool bootstrap [--dry-run] [--force]   所有项目 install（**不做系统层**）
#
#   ── 出问题 ─────────────────────────────────────────────────
#   wtool                 裸跑 = 项目表（一行一个项目、一列一个能力）
#   wtool check   [<项目>]        声明 / 日志 / 磁盘 三者对比，只报不改
#   wtool repair  [<项目>|all]    修 check 报出来的（只重建、不删除）
#   wtool status  [<项目目录>]    登记表 + 软链检查
#   wtool doctor                  环境诊断（含环境变量与项目表）
#   wtool validate <项目目录>     检查 wtool.xml 写得对不对
#   wtool init    <目录> [--id ID] [--priority N] [--all]
#   wtool kill-self-forever       删掉 wtool 的一切痕迹（含 state；要逐字确认）
#   wtool version
#
# 一条铁律：**要 sudo 的都叫 sudo-\*；不叫 sudo-\* 的永远不要 sudo，也永远不碰网络。**
# 设计原则：Python 只算不写（除 scratch），Shell 只写不算（除读 journal）。
# 详见 docs/spec.md。
set -eu

ENGINE_VERSION="1.0.0"

self=$(readlink -f -- "$0" 2>/dev/null || echo "$0")
here=$(dirname -- "$self")

WTOOL_BOOTSTRAP=${WTOOL_BOOTSTRAP:-$here}
WTOOL_HOME=${WTOOL_HOME:-$HOME}
if [ -z "${WTOOL_STATE:-}" ]; then
    if [ -n "${XDG_STATE_HOME:-}" ]; then
        WTOOL_STATE="$XDG_STATE_HOME/wtool"
    else
        WTOOL_STATE="$WTOOL_HOME/.local/state/wtool"
    fi
fi
# 必须 export：planner 和项目脚本都要读它。
# 不导出的话 Python 侧读不到，会退化用 basename 当项目 id。
WTOOL_ROOT=${WTOOL_ROOT:-$(dirname -- "$here")}
export WTOOL_ROOT
WTOOL_REGISTRY="$WTOOL_STATE/registry.tsv"
WTOOL_SRC=${WTOOL_SRC:-$WTOOL_HOME/.wtool/src}
WTOOL_PREFIX=${WTOOL_PREFIX:-$WTOOL_HOME/.wtool/usr}
WTOOL_FORCE=0
WTOOL_DRY_RUN=0
# 注意：`--with-system` 已经删掉（sudo-install 本来就是系统层），
# 所以这里没有 WTOOL_WITH_SYSTEM 这个开关了。

. "$here/lib/wtool_fs.sh"
. "$here/lib/wtool_os.sh"
wt_os_detect        # 引擎自己探测，不依赖交互 shell 的环境

PY="$here/lib/wtool_plan.py"
[ -f "$PY" ] || wt_die "缺少规划器: $PY"

# 前置依赖硬检查：缺了就给一条能直接复制的命令
# （最小化系统/docker 镜像里 python3 和 git 都可能没有，见 docs/spec.md §12）
#
# `sudo` 不能无脑写：最小化的 docker 镜像里**根本没有 sudo**，
# 而以 root 跑的时候也不需要它。写了 sudo 的后果是用户照着复制，
# 得到一句 "sudo: command not found" —— 我们明明是想帮他，结果又给他添了一个错。
wt_priv() {
    # 输出"需要提权"时该加的前缀：root 下是空，非 root 且有 sudo 才是 sudo
    if [ "$(id -u 2>/dev/null || echo 0)" = 0 ]; then
        printf ''
    elif command -v sudo >/dev/null 2>&1; then
        printf 'sudo '
    else
        printf ''
    fi
}

_wt_missing=""
command -v python3 >/dev/null 2>&1 || _wt_missing="$_wt_missing python3"
command -v git >/dev/null 2>&1 || _wt_missing="$_wt_missing git"
if [ -n "$_wt_missing" ]; then
    _wt_p=$(wt_priv)
    wt_die "缺少依赖:$_wt_missing
请先执行（用系统自带源，不需要证书）：
  ${_wt_p}apt-get update && ${_wt_p}apt-get install -y --no-install-recommends ca-certificates git python3"
fi

# --------------------------------------------------------------------------
# 小工具
# --------------------------------------------------------------------------
wt_now() { date +%Y-%m-%dT%H:%M:%S%z; }

wt_meta_get() {
    _file=$1; _key=$2
    [ -f "$_file" ] || return 1
    awk -F'\t' -v k="$_key" '$1==k {print $2; found=1} END{exit !found}' "$_file"
}

# 这个目录是不是"从发布包解压出来的副本"？
#
# 是的话就不该要求它是 git 仓库——发布包里没有 .git（带了会大好几倍，
# 而且 clone 出来的历史对"我只想装上用"的人毫无意义）。
# 每个源码包都会带一个 wtool/.wtool-dist/<id>.json 标记，记着打包时的
# commit 和来源仓，正好拿来当版本信息，比 git 还准（它记的是发布那一刻）。
wt_release_marker() {   # <项目目录> → 打印标记文件路径
    _rm_dir=$1
    _rm_ws=$(python3 -c '
import os, sys
p, root = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
print(os.path.relpath(p, root))
' "$_rm_dir" "$WTOOL_ROOT" 2>/dev/null) || return 1
    case $_rm_ws in ..|../*|/*) return 1 ;; esac
    _rm_name=$(printf '%s' "$_rm_ws" | tr '/' '-')
    _rm_file="$WTOOL_ROOT/.wtool-dist/$_rm_name.json"
    [ -f "$_rm_file" ] && printf '%s\n' "$_rm_file"
}

wt_git_precheck() {
    _dir=$1

    # 发布包解压出来的副本：认标记，不认 .git
    _marker=$(wt_release_marker "$_dir" 2>/dev/null || true)
    if [ -n "$_marker" ] && ! git -C "$_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        _mcommit=$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    print(json.load(fh).get("commit") or "-")
' "$_marker" 2>/dev/null || echo "-")
        _mrepo=$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    print(json.load(fh).get("repo") or "-")
' "$_marker" 2>/dev/null || echo "-")
        WTOOL_HEAD=$(printf '%s' "$_mcommit" | cut -c1-12)
        wt_info "这是发布副本（$_mrepo @ ${WTOOL_HEAD}），跳过 git 检查"
        return 0
    fi

    if git -C "$_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if [ -n "$(git -C "$_dir" status --porcelain -uno 2>/dev/null)" ]; then
            if [ "${WTOOL_FORCE:-0}" = 1 ]; then
                wt_warn "$_dir 有未提交的已跟踪改动（--force 继续），记录的版本不准确"
            else
                wt_die "$_dir 有未提交的已跟踪改动，请先提交后再 install（或用 --force）"
            fi
        fi
        WTOOL_HEAD=$(git -C "$_dir" rev-parse --short=12 HEAD 2>/dev/null || echo "-")
    elif [ -e "$_dir/.git" ]; then
        # 有 .git 但 git 拒绝使用：最常见的是"属主不一致"（容器里以 root 访问宿主的仓库）
        _why=$(git -C "$_dir" rev-parse --is-inside-work-tree 2>&1 | head -1)
        wt_die "git 拒绝使用 $_dir 的仓库：
  $_why
如果是在容器里以 root 访问宿主目录，执行一次即可：
  git config --global --add safe.directory '*'
或者给 install 加 --force 跳过版本检查"
    else
        if [ "${WTOOL_FORCE:-0}" = 1 ]; then
            wt_warn "$_dir 不是 git 仓库（--force 继续），无法记录版本"
            WTOOL_HEAD="-"
        else
            wt_die "$_dir 不是 git 仓库；请先 git init + commit，或用 --force"
        fi
    fi
}

wt_load_project() {
    # 读 scratch/meta.tsv，设置 WTOOL_PROJECT_ID / WTOOL_JOURNAL / WTOOL_META
    # 注意：journal 永不截断 —— 它记录"当前该撤销什么"，
    # 重复 install 只更新条目；一旦清空，uninstall 就失去了回退依据。
    WTOOL_PROJECT_ID=$(wt_meta_get "$1/meta.tsv" project_id) \
        || wt_die "规划器没有产出 project_id"
    WTOOL_PROJECT_ROOT=$(wt_meta_get "$1/meta.tsv" project_root) || true
    WTOOL_PROJECT_DIR="$WTOOL_STATE/$WTOOL_PROJECT_ID"
    WTOOL_JOURNAL="$WTOOL_PROJECT_DIR/journal.tsv"
    WTOOL_META="$WTOOL_PROJECT_DIR/meta.tsv"
    if ! wt_dry; then
        mkdir -p -- "$WTOOL_PROJECT_DIR"
        [ -f "$WTOOL_JOURNAL" ] || : > "$WTOOL_JOURNAL"
    fi
}

wt_print_plan() {
    _plan=$1
    if [ ! -s "$_plan" ] || ! grep -qv '^reg	' "$_plan" 2>/dev/null; then
        wt_info "没有需要变更的内容（已是最新）"
        return 0
    fi
    while IFS='	' read -r _action _kind _dest _source _sha _extra; do
        [ -z "${_action:-}" ] && continue
        case $_action in
            link) wt_step "link  $_dest -> $_source" ;;
            rc)   wt_step "rc    $_dest" ;;
        esac
    done < "$_plan"
}


# --------------------------------------------------------------------------
# all 的展开
#
# 四个动作命令统一规矩：
#   不带参数       只列出来，不动任何东西
#   <项目>         对那一个动手
#   all            对全部动手
#
# 为什么裸命令不等于 all：`wtool install` 误触一次就往 $HOME 里铺一堆东西，
# 而"我想看看有哪些项目"是高频得多的操作。默认安全，要动手就明写。
# --------------------------------------------------------------------------
wt_all_projects() {   # <过滤条件>：build | download | install | publish | sudo | 空=全部
    _ap_filter=$1
    _ap_sudo=""
    if [ "$_ap_filter" = "sudo" ]; then
        _ap_sudo=$(python3 "$PY" sudo-list --root "$WTOOL_ROOT" | cut -f2)
    fi
    python3 "$PY" publish-list --root "$WTOOL_ROOT" |
    while IFS='	' read -r _prio _pid _path _kind _script _tpl _to; do
        [ -n "${_pid:-}" ] || continue
        case $_ap_filter in
            build)    wt_project_script "$_path" build.sh    >/dev/null 2>&1 || continue ;;
            # 「能下载」= 项目里**提交了** scripts/release.json（ADR-026）
            download) [ -f "$_path/scripts/release.json" ] || continue ;;
            publish)  [ "$_kind" = "none" ] && continue ;;
            sudo)     printf '%s\n' "$_ap_sudo" | grep -qxF -- "$_pid" || continue ;;
            install)  ;;
        esac
        printf '%s\n' "$_pid"
    done
}

# 把参数里的 all 展开；返回空格分隔的项目名
wt_expand_targets() {   # <过滤条件> <参数...>
    _et_filter=$1; shift
    _et_out=""
    for _et_a in "$@"; do
        if [ "$_et_a" = "all" ]; then
            _et_out="$_et_out $(wt_all_projects "$_et_filter" | tr '\n' ' ')"
        else
            _et_out="$_et_out $_et_a"
        fi
    done
    printf '%s\n' "$_et_out"
}

# --------------------------------------------------------------------------
# 项目自己的脚本：build.sh / install.sh（发布和下载不用写脚本，见 ADR-023）
#
# 约定（见 guide.md「项目拓扑」）：
#   子项目只提供 wtool.xml + 自己需要的脚本和源码，剩下的全交给 wtool。
#   引擎负责按名找到脚本、喂好环境变量、把输出透到终端；
#   脚本自己决定做什么，不需要知道 wtool 的内部结构。
#
# 存在性检查是**能力标记**的来源：表格里哪一列亮绿，就看这个脚本在不在。
# --------------------------------------------------------------------------
#
# 脚本固定放在 <项目>/scripts/ 下：
#     terminal/tmux/scripts/build.sh
#     editor/astronvim_v5/scripts/build.sh
#
# 为什么单独一层目录，而不是散在项目根：项目根上放的是**内容和声明**
# （wtool.xml、配置文件、源码），scripts/ 下放的是**动作**。
# 分开之后一眼能看出"这个项目会对我做什么"。
#
# 兼容：老位置（项目根）也认，但会警告。等项目都迁完就只认 scripts/。
wt_project_script() {   # <项目目录> <脚本名>  → 打印脚本绝对路径，没有则返回 1
    _ps_dir=$1; _ps_name=$2
    if [ -f "$_ps_dir/scripts/$_ps_name" ]; then
        printf '%s\n' "$_ps_dir/scripts/$_ps_name"
        return 0
    fi
    if [ -f "$_ps_dir/$_ps_name" ]; then
        wt_warn "  $_ps_name 还在项目根目录，应该挪到 scripts/ 下：$_ps_dir"
        printf '%s\n' "$_ps_dir/$_ps_name"
        return 0
    fi
    return 1
}

# 跑项目脚本：喂环境变量、cd 到项目目录、stdin 接 /dev/null
wt_run_project_script() {   # <项目目录> <脚本名> [额外参数...]
    _rs_dir=$1; _rs_name=$2; shift 2
    _rs_path=$(wt_project_script "$_rs_dir" "$_rs_name") || return 1
    # 脚本可能在容器/独立环境里跑，所以路径提前算好喂给它，
    # 不要求脚本自己去推 WTOOL_STATE 和项目 id
    WTOOL_ARTIFACTS="$WTOOL_STATE/${WTOOL_PROJECT_ID:-$(basename -- "$_rs_dir")}/artifacts.tsv"
    if ! wt_dry; then
        mkdir -p -- "$(dirname -- "$WTOOL_ARTIFACTS")"
    fi

    # dry-run 时把 --dry-run 转给脚本，让它自己把计划打出来。
    # 直接跳过的话，"wtool build xxx --dry-run"就只会说一句"要执行 build.sh"，
    # 等于什么都没告诉你。脚本要支持 --dry-run（模板里有）。
    _rs_args="$*"
    if wt_dry; then
        _rs_args="$_rs_args --dry-run"
    fi

    (
        # 项目脚本能拿到的环境（和 provision 任务的约定保持一致）
        export WTOOL_PROJECT_ID="${WTOOL_PROJECT_ID:-$(basename -- "$_rs_dir")}"
        export WTOOL_PROJECT_DIR="$_rs_dir"
        export WTOOL_PROJECT_ROOT="$_rs_dir"
        export WTOOL_WORKSPACE="$WTOOL_ROOT"
        export WTOOL_HOME
        export WTOOL_PREFIX WTOOL_JOBS WTOOL_ARCH
        export WTOOL_OS_ID WTOOL_OS_VERSION WTOOL_OS_CODENAME WTOOL_OS_LIKE
        # 产物清单：脚本用它声明"我产出了什么"。install / uninstall /
        # publish / 表格 全都读它，谁都不许靠猜（见 guide.md「产物契约」）。
        export WTOOL_ARTIFACTS
        export WTOOL_STATE_DIR="$WTOOL_STATE/$WTOOL_PROJECT_ID"
        cd -- "$_rs_dir" || exit 1
        # stdin 接 /dev/null：脚本不该从终端读，也不该偷引擎的输入
        # （清单走 fd 3，就是为了防这个——见 cmd_publish_release 的注释）
        # shellcheck disable=SC2086
        exec sh "$_rs_path" $_rs_args < /dev/null
    )
}


# --------------------------------------------------------------------------
# 构建门槛
#
# 有些项目的构建很重（astronvim_v5 要编 nvim、装 75 个 mason 包、
# 编 251 个 treeseitter parser，峰值 10G 磁盘、几 G 内存）。
# 在这种机器上硬跑只会跑一小时后失败，不如一开始就说清楚，
# 并把它导向"下载现成的包"这条路。
#
# 门槛按项目声明（wtool.xml 里的 <build min-cores= min-mem= min-disk=/>），
# 引擎给一个宽松的默认值兜底 —— 写死在引擎里的话，tmux 那种纯配置项目
# 也会被无意义地拦一下。
# --------------------------------------------------------------------------
wt_default_min_cores=4
wt_default_min_mem_gb=8
wt_default_min_disk_gb=10

wt_check_build_env() {   # <项目目录> <项目 id> → 不满足返回 1
    _ce_dir=$1; _ce_pid=$2
    _ce_cores=$wt_default_min_cores
    _ce_mem=$wt_default_min_mem_gb
    _ce_disk=$wt_default_min_disk_gb

    # 项目自己在 wtool.xml 里声明的要求
    _ce_xml="$_ce_dir/wtool.xml"
    if [ -f "$_ce_xml" ]; then
        _ce_vals=$(python3 - "$_ce_xml" <<'PYGATE' 2>/dev/null || true
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    sys.exit(0)
for b in root.iter("build"):
    print(b.get("min-cores") or "", b.get("min-mem") or "", b.get("min-disk") or "")
PYGATE
)
        [ -n "$_ce_vals" ] && set -- $_ce_vals && {
            [ -n "${1:-}" ] && _ce_cores=$1
            [ -n "${2:-}" ] && _ce_mem=$2
            [ -n "${3:-}" ] && _ce_disk=$3
        }
    fi

    _ce_have_cores=$(nproc 2>/dev/null || echo 1)
    _ce_have_mem=$(awk '/^MemTotal:/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)
    _ce_have_disk=$(df -Pk "$WTOOL_HOME" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}' || echo 0)

    _ce_bad=""
    [ "$_ce_have_cores" -ge "$_ce_cores" ] || _ce_bad="$_ce_bad
    CPU 核心：有 $_ce_have_cores，需要 $_ce_cores"
    [ "$_ce_have_mem" -ge "$_ce_mem" ] || _ce_bad="$_ce_bad
    内存：有 ${_ce_have_mem}G，需要 ${_ce_mem}G"
    [ "$_ce_have_disk" -ge "$_ce_disk" ] || _ce_bad="$_ce_bad
    磁盘（\$HOME 所在分区）：有 ${_ce_have_disk}G，需要 ${_ce_disk}G"

    [ -z "$_ce_bad" ] && return 0

    if [ "${WTOOL_FORCE:-0}" = 1 ]; then
        wt_warn "  $_ce_pid 的构建环境不达标，--force 继续：$_ce_bad"
        return 0
    fi

    wt_warn "  $_ce_pid 的构建环境不达标：$_ce_bad"
    wt_warn ""
    wt_warn "  这台机器上硬编会很慢，而且多半会在中途因为磁盘或内存失败。"
    wt_warn "  建议改成下载现成的包（发布页上已经有人编好了）："
    wt_warn "      wtool download-release $_ce_pid  然后 wtool unpack-release $_ce_pid"
    wt_warn "      wtool install  $_ce_pid"
    wt_warn ""
    wt_warn "  确认要在这台机器上编，就加 --force。"
    return 1
}

# 并行度按内存封顶。
# 32 核配 16G 内存的机器很常见，WTOOL_JOBS=nproc 会让 nvim 的构建 OOM ——
# 核心数只决定快慢，内存不够是直接失败。
wt_effective_jobs() {
    # 默认就是 nproc —— 不要凭"32 核配 24G 大概会 OOM"这种猜测去砍并行度，
    # 那会让一台完全跑得动的机器慢上两倍多，而且没有任何测量依据。
    #
    # 只在明显失衡的机器上才轻微封顶：核心数远超内存（比如 32 核 8G）。
    # 按 1 核约 1G 算，够宽松。想自己控制就设 WTOOL_JOBS。
    _ej_cores=${WTOOL_JOBS:-$(nproc 2>/dev/null || echo 4)}
    _ej_mem=$(awk '/^MemTotal:/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)
    [ "$_ej_mem" -gt 0 ] || { printf '%s\n' "$_ej_cores"; return 0; }
    if [ "$_ej_cores" -gt "$_ej_mem" ]; then
        wt_warn "  并行度从 -j$_ej_cores 降到 -j$_ej_mem：核心数远超内存（${_ej_mem}G）"
        wt_warn "  想用满就设 WTOOL_JOBS=$_ej_cores（后果自负）"
        _ej_cores=$_ej_mem
    fi
    printf '%s\n' "$_ej_cores"
}

# --------------------------------------------------------------------------
# build：跑项目自己的 build.sh
#
# 「能构建」这件事只有项目自己知道——编什么、要不要 docker、产物在哪。
# 引擎不做任何假设，只负责找到脚本、把环境喂好、把输出原样透出来。
# --------------------------------------------------------------------------
cmd_build() {
    _targets=""
    for arg in "$@"; do
        case $arg in
            --dry-run) WTOOL_DRY_RUN=1 ;;
            --force)   WTOOL_FORCE=1 ;;
            -*)        wt_die "未知参数: $arg" ;;
            *)         _targets="$_targets $arg" ;;
        esac
    done

    if [ -z "$_targets" ]; then
        # 不带参数：只列出来，不动任何东西（要动手写 all）
        wt_info "这些项目提供了 scripts/build.sh："
        _n=0
        while IFS='	' read -r _prio _pid _path _kind _script _tpl _to; do
            [ -n "${_pid:-}" ] || continue
            if [ -f "$_path/build.sh" ]; then
                wt_step "$_pid"
                _n=$((_n + 1))
            fi
        done <<EOF
$(python3 "$PY" publish-list --root "$WTOOL_ROOT")
EOF
        [ "$_n" -gt 0 ] || wt_info "  （一个都没有）"
        wt_info "构建其中一个：wtool build <项目>；全部：wtool build all"
        return 0
    fi

    _targets=$(wt_expand_targets build $_targets)
    [ -n "$(printf '%s' "$_targets" | tr -d ' ')" ] || wt_die "没有匹配的项目（试试 wtool build 看有哪些）"

    _done=0
    for _want in $_targets; do
        _row=$(wt_publish_resolve "$_want") || exit $?
        _pid=$(printf '%s\n' "$_row" | cut -f2)
        _path=$(printf '%s\n' "$_row" | cut -f3)

        wt_info "── $_pid"
        if ! wt_project_script "$_path" build.sh >/dev/null; then
            wt_warn "  没有 build.sh，这个项目不需要构建"
            continue
        fi
        wt_info "  脚本 : scripts/build.sh"
        WTOOL_PROJECT_ID=$_pid
        wt_check_build_env "$_path" "$_pid" || continue
        WTOOL_JOBS=$(wt_effective_jobs)
        wt_info "  并行 : -j$WTOOL_JOBS（按内存封顶，nproc=$(nproc 2>/dev/null || echo ?)）"
        wt_record_action "$_pid" build
        wt_run_project_script "$_path" build.sh || wt_die "build.sh 失败: $_pid"
        _done=$((_done + 1))
    done
    wt_info "build 完成（$_done 个项目）"
}

# --------------------------------------------------------------------------
# download-release：从 GitHub Release 把包下到 <项目>/release/
#
# **它只干一件事**：下载 + 校验 + 落到 `release/`。**不解包、不认包结构** ——
# 解包是 `unpack-release` 的事（ADR-023：四条边各自单一职责）。
#
# 该下什么、每个文件的 sha256 是多少，一律读**项目里提交的** `scripts/release.json`：
# 那份清单在 git 里，所以"清单和包同源、等于没校验"这个弱点在这里不存在（ADR-026）。
# 只有浏览器的机器没有仓库 —— 那种场景走 docs/download.md 手动下 + unpack-release。
#
# 网络两条路（实测换来的，别删）：直链 `github.com/.../releases/download/...`
# 有时整个不通，而 `api.github.com` 通；所以直链失败要再走一次 API 的资产端点
# （`Accept: application/octet-stream`）。**两条都失败才算失败。**
# --------------------------------------------------------------------------
wt_dl_one() {   # <url> <目标文件> <sha256>（sha256 空 = 不校验）
    _d_url=$1; _d_out=$2; _d_sha=$3
    _d_part="$_d_out.part"
    rm -f -- "$_d_part"
    # --speed-limit/--speed-time：代理"慢慢磨"的时候要自己判失败，
    # 而不是挂在那里永远不报错（这个项目在这上面吃过亏）。
    if ! curl -fL --retry 3 --retry-delay 2 -C - \
              --connect-timeout 15 --speed-limit 4096 --speed-time 60 \
              -o "$_d_part" "$_d_url" 2>/dev/null; then
        rm -f -- "$_d_part"
        return 1
    fi
    if [ -n "$_d_sha" ]; then
        _d_got=$(sha256sum -- "$_d_part" 2>/dev/null | cut -d' ' -f1)
        if [ "$_d_got" != "$_d_sha" ]; then
            rm -f -- "$_d_part"
            return 2
        fi
    fi
    mv -f -- "$_d_part" "$_d_out"
    return 0
}

# 资产名 → API 的资产 id（route B 要用）。不联网失败就吐空。
wt_dl_asset_ids() {   # <repo> <tag>
    curl -fsSL --connect-timeout 15 --max-time 60 \
         -H 'Accept: application/vnd.github+json' \
         "https://api.github.com/repos/$1/releases/tags/$2" 2>/dev/null |
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for a in d.get("assets") or []:
    sys.stdout.write("%s\t%s\n" % (a.get("name", ""), a.get("id", "")))
'
}

cmd_download_release() {
    _targets=""
    for arg in "$@"; do
        case $arg in
            --dry-run) WTOOL_DRY_RUN=1 ;;
            -*)        wt_die "未知参数: $arg" ;;
            *)         _targets="$_targets $arg" ;;
        esac
    done

    if [ -z "$_targets" ]; then
        wt_info "这些项目提交了 scripts/release.json（可以直接下现成的包）："
        _n=0
        while IFS='	' read -r _prio _pid _path _kind _script _tpl _to; do
            [ -n "${_pid:-}" ] || continue
            if [ -f "$_path/scripts/release.json" ]; then
                wt_step "$_pid"
                _n=$((_n + 1))
            fi
        done <<EOF
$(python3 "$PY" publish-list --root "$WTOOL_ROOT")
EOF
        [ "$_n" -gt 0 ] || wt_info "  （一个都没有）"
        wt_info "下载其中一个：wtool download-release <项目>；全部：wtool download-release all"
        wt_info "下完还要 wtool unpack-release <项目> 才产出 output/ —— 两步是分开的。"
        return 0
    fi

    command -v curl >/dev/null 2>&1 || wt_die "download-release 需要 curl"

    _targets=$(wt_expand_targets download $_targets)
    [ -n "$(printf '%s' "$_targets" | tr -d ' ')" ] || wt_die "没有匹配的项目（试试 wtool download-release 看有哪些）"

    _done=0
    for _want in $_targets; do
        # 和 unpack-release 一样：**先认目录**。目录形式不该要求它已经在项目表里
        # —— 刚从发布包铺开的工作区就是这种情况（还没有 wtool.xml 之外的账）。
        _path=""
        case $_want in
            /*) [ -d "$_want" ] && _path=$(cd -- "$_want" && pwd) ;;
            *)  [ -d "$WTOOL_ROOT/$_want" ] && _path=$(cd -- "$WTOOL_ROOT/$_want" && pwd) ;;
        esac
        if [ -n "$_path" ]; then
            case $_path in
                "$WTOOL_ROOT"/*) _pid=${_path#"$WTOOL_ROOT"/} ;;
                *)                _pid=$(basename -- "$_path") ;;
            esac
        else
            _row=$(wt_publish_resolve "$_want") || exit $?
            _pid=$(printf '%s\n' "$_row" | cut -f2)
            _path=$(printf '%s\n' "$_row" | cut -f3)
        fi
        _rl="$_path/scripts/release.json"

        wt_info "── $_pid"
        if [ ! -f "$_rl" ]; then
            wt_warn "  没有 scripts/release.json —— 这个项目还没发布过现成的包，"
            wt_warn "  只能自己编：wtool build $_pid"
            continue
        fi

        # 清单里每一行：名字 <TAB> sha256 <TAB> 字节 <TAB> 直链（已百分号编码）
        _rows=$(python3 - "$_rl" <<'PY'
import json, sys, urllib.parse
d = json.load(open(sys.argv[1], encoding="utf-8"))
base = d.get("base_url") or "https://github.com/%s/releases/download/%s" % (
    d.get("repo", ""), d.get("tag", ""))
for a in d.get("assets") or []:
    name = a.get("name", "")
    if not name:
        continue
    print("%s\t%s\t%s\t%s/%s" % (name, a.get("sha256", ""), a.get("bytes", 0),
                                 base.rstrip("/"), urllib.parse.quote(name)))
PY
) || wt_die "读不了 $_rl"
        [ -n "$_rows" ] || { wt_warn "  release.json 里一个资产都没有，跳过"; continue; }

        _repo=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8")).get("repo",""))' "$_rl")
        _tag=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8")).get("tag",""))' "$_rl")
        wt_info "  清单 : scripts/release.json（$_repo $_tag）"
        wt_info "  落点 : release/"

        if wt_dry; then
            printf '%s\n' "$_rows" | while IFS='	' read -r _n _s _b _u; do
                wt_step "[dry-run] $_n  ← $_u"
            done
            _done=$((_done + 1))
            continue
        fi

        mkdir -p -- "$_path/release"
        _ids=""
        _ids_fetched=0
        _got=0
        while IFS='	' read -r _n _s _b _u; do
            [ -n "${_n:-}" ] || continue
            _dest="$_path/release/$_n"
            # 已经下好了（sha 对得上）就跳过 —— 重跑是幂等的
            if [ -f "$_dest" ] && [ -n "$_s" ] && \
               [ "$(sha256sum -- "$_dest" 2>/dev/null | cut -d' ' -f1)" = "$_s" ]; then
                wt_step "$_n（已是最新，跳过）"
                _got=$((_got + 1))
                continue
            fi
            wt_step "$_n  ← 直链"
            _rc=0
            wt_dl_one "$_u" "$_dest" "$_s" || _rc=$?
            if [ "$_rc" != 0 ]; then
                # 直链不通 → 走 API 的资产端点（第二条路）
                if [ "$_ids_fetched" = 0 ]; then
                    _ids=$(wt_dl_asset_ids "$_repo" "$_tag" || true)
                    _ids_fetched=1
                fi
                _id=$(printf '%s\n' "$_ids" | awk -F'\t' -v n="$_n" '$1==n{print $2; exit}')
                if [ -n "$_id" ]; then
                    wt_warn "  直链不通，改走 api.github.com 的资产端点"
                    _u2="https://api.github.com/repos/$_repo/releases/assets/$_id"
                    _rc=0
                    wt_dl_one_api "$_u2" "$_dest" "$_s" || _rc=$?
                fi
                if [ "$_rc" != 0 ]; then
                    wt_warn "  $_n 两条路都失败（退出码 $_rc）—— 这个文件没下来"
                    continue
                fi
            fi
            _got=$((_got + 1))
        done <<EOF
$_rows
EOF
        if [ "$_got" -eq 0 ]; then
            wt_warn "  一个文件都没下来"
            continue
        fi

        # 来源标记：publish-release 靠它拒绝"把刚下下来的包又传回去"（ADR-026）
        printf 'downloaded\t%s\t%s\t%s\n' "$_repo" "$_tag" "$(date -Iseconds)" \
            > "$_path/release/.source"
        wt_record_action "$_pid" download
        wt_info "  下了 $_got 个文件"
        wt_info "  下一步: wtool unpack-release $_pid"
        _done=$((_done + 1))
    done
    wt_info "download-release 完成（$_done 个项目）"
}

# route B：API 的资产端点，要带 Accept: application/octet-stream
wt_dl_one_api() {   # <url> <目标文件> <sha256>
    _a_url=$1; _a_out=$2; _a_sha=$3
    _a_part="$_a_out.part"
    rm -f -- "$_a_part"
    if ! curl -fL --retry 3 --retry-delay 2 -C - \
              -H 'Accept: application/octet-stream' \
              --connect-timeout 15 --speed-limit 4096 --speed-time 60 \
              -o "$_a_part" "$_a_url" 2>/dev/null; then
        rm -f -- "$_a_part"
        return 1
    fi
    if [ -n "$_a_sha" ]; then
        _a_got=$(sha256sum -- "$_a_part" 2>/dev/null | cut -d' ' -f1)
        if [ "$_a_got" != "$_a_sha" ]; then
            rm -f -- "$_a_part"
            return 2
        fi
    fi
    mv -f -- "$_a_part" "$_a_out"
    return 0
}

# --------------------------------------------------------------------------
# install
# --------------------------------------------------------------------------
cmd_install() {
    _project=""
    _no_script=0
    for arg in "$@"; do
        case $arg in
            --dry-run)   WTOOL_DRY_RUN=1 ;;
            --force)     WTOOL_FORCE=1 ;;
            --no-script) _no_script=1 ;;
            -*)          wt_die "未知参数: $arg" ;;
            *)           _project=$arg ;;
        esac
    done
    [ -n "$_project" ] || wt_die "用法: wtool.sh install <项目目录> [--dry-run] [--force] [--no-script]"
    [ -d "$_project" ] || wt_die "项目目录不存在: $_project"
    _project=$(cd -- "$_project" && pwd)

    wt_git_precheck "$_project"

    # 产物检查（§4.1）：项目里有 build.sh ⟺ 装之前 output/ 得在。
    # 理由：install 是**断网也要能跑**的，所以它不替你去编译或下载 ——
    # 但也不能装作没事，那样装出来的是半成品。
    if wt_project_script "$_project" build.sh >/dev/null 2>&1 \
       ; then
        if [ -z "$(ls -A -- "$_project/output" 2>/dev/null)" ]; then
            if [ "${WTOOL_FORCE:-0}" = 1 ]; then
                wt_warn "output/ 还没有东西（--force 继续），装出来的可能不完整"
            else
                wt_die "$_project 要先产出产物（output/ 是空的）：
  wtool download-release $_project   # 下现成的包到 release/（要联网）
  wtool unpack-release   $_project   # 拼分卷 + 解到 output/
  wtool build    $_project      # 或者自己编（可能要几十分钟）
install 不替你做这个决定 —— 它永不联网。"
            fi
        fi
    fi

    _scratch=$(mktemp -d "${TMPDIR:-/tmp}/wtool.XXXXXX")
    trap 'rm -rf -- "$_scratch"' EXIT INT TERM

    wt_info "规划 $_project"
    python3 "$PY" plan-install "$_project" \
        --home "$WTOOL_HOME" --state "$WTOOL_STATE" --scratch "$_scratch" \
        --head "$WTOOL_HEAD" --at "$(wt_now)" \
        $([ "$WTOOL_FORCE" = 1 ] && echo --force) || exit $?

    wt_load_project "$_scratch"
    wt_info "project: $WTOOL_PROJECT_ID"
    wt_print_plan "$_scratch/plan.tsv"
    wt_print_plan "$_scratch/plan.home.tsv"

    # 执行顺序（§4.2，和以前相反，别改回去）：
    #   ① 引擎基建：中转链接 + env 块
    #   ① 项目自己的 install.sh：output/ → ~/.wtool
    #   ② wtool.xml 的 link：影子 HOME → $HOME
    # ②建的软链**指向**①铺出来的东西，顺序反了就是先建一堆悬空链接。
    wt_plan_exec "$_scratch/plan.tsv"

    # ⚠️ 正因为引擎会跑 install.sh，**项目里不能再放"调用 wtool install"的存根**，
    #    那会变成 install.sh → wtool install → install.sh 的无限递归。
    if [ "$_no_script" = 1 ]; then
        wt_info "跳过项目自己的 install.sh（--no-script）"
    elif wt_project_script "$_project" install.sh >/dev/null; then
        wt_info "项目脚本: install.sh（output/ → ~/.wtool）"
        wt_run_project_script "$_project" install.sh || wt_die "install.sh 失败: $WTOOL_PROJECT_ID"
    fi

    wt_plan_exec "$_scratch/plan.home.tsv"

    if ! wt_dry; then
        cp -f -- "$_scratch/meta.tsv" "$WTOOL_META"
        printf 'installed_at\t%s\n' "$(wt_now)" >> "$WTOOL_META"
        printf 'engine\t%s\n' "$ENGINE_VERSION" >> "$WTOOL_META"
    fi

    # 全量重算环境变量汇总（用户的 rc 里始终只有一个 loader 块），
    # 顺带保证 ~/usr → ~/.wtool/usr 这条全局软链在（§8）。
    wt_env_sync

    wt_info "install 完成"
}

# --------------------------------------------------------------------------
# uninstall
# --------------------------------------------------------------------------
cmd_uninstall() {
    _project=""
    _id=""
    while [ $# -gt 0 ]; do
        case $1 in
            --dry-run) WTOOL_DRY_RUN=1 ;;
            --force)   WTOOL_FORCE=1 ;;
            --no-script) WTOOL_NO_SCRIPT=1 ;;   # 跳过项目自己的 install.sh --uninstall
            --id)      shift; _id=${1:-} ;;
            -*)        wt_die "未知参数: $1" ;;
            *)         _project=$1 ;;
        esac
        shift
    done
    [ -n "$_project" ] || [ -n "$_id" ] || wt_die "用法: wtool uninstall <项目目录>|--id <id>|all [--dry-run] [--force] [--no-script]"

    # `all` = 卸掉所有装过的项目（判据是 state 里的账，不是项目表：
    # 项目目录可能已经不在磁盘上了，那种情况正好靠 --id 也卸得掉）。
    if [ "$_project" = "all" ]; then
        _all_ids=$(wt_installed_ids)
        if [ -z "$_all_ids" ]; then
            wt_info "没有装过的项目（state 是空的）"
            return 0
        fi
        wt_info "卸掉所有装过的项目："
        for _ai in $_all_ids; do
            wt_step "$_ai"
        done
        _rc_all=0
        for _ai in $_all_ids; do
            _force_all=""
            [ "${WTOOL_FORCE:-0}" = 1 ] && _force_all="--force"
            [ "${WTOOL_DRY_RUN:-0}" = 1 ] && _force_all="$_force_all --dry-run"
            _noscript_all=""
            [ "${WTOOL_NO_SCRIPT:-0}" = 1 ] && _noscript_all="--no-script"
            # shellcheck disable=SC2086
            cmd_uninstall --id "$_ai" $_force_all $_noscript_all || _rc_all=1
        done
        [ "$_rc_all" = 0 ] && wt_info "uninstall all 完成" || wt_warn "有些项目没卸干净"
        return $_rc_all
    fi

    _scratch=$(mktemp -d "${TMPDIR:-/tmp}/wtool.XXXXXX")
    trap 'rm -rf -- "$_scratch"' EXIT INT TERM

    if [ -n "$_project" ]; then
        _project=$(cd -- "$_project" && pwd)
        python3 "$PY" plan-uninstall "$_project" \
            --home "$WTOOL_HOME" --state "$WTOOL_STATE" --scratch "$_scratch" \
            $([ "$WTOOL_FORCE" = 1 ] && echo --force) || exit $?
    else
        python3 "$PY" plan-uninstall --id "$_id" \
            --home "$WTOOL_HOME" --state "$WTOOL_STATE" --scratch "$_scratch" \
            $([ "$WTOOL_FORCE" = 1 ] && echo --force) || exit $?
    fi

    wt_load_project "$_scratch"
    wt_info "project: $WTOOL_PROJECT_ID"

    # 0) 拆 $HOME 软链之前先问一句：**还有别的项目要这条软链吗？**
    #    判据是磁盘上所有 wtool 项目的 wtool.xml（§4.2），不是 registry ——
    #    registry 一条落点只能有一个主人，而"两个项目都要 ~/.gitconfig"
    #    是完全合理的。有别人要用就留着，把登记改成那个项目。
    _claims=$(mktemp "${TMPDIR:-/tmp}/wtool-claims.XXXXXX")
    python3 "$PY" claimed --root "$WTOOL_ROOT" --home "$WTOOL_HOME" \
        --exclude-id "$WTOOL_PROJECT_ID" > "$_claims" 2>/dev/null || : > "$_claims"

    # 1) rc 回退（内容由 py 算好，sh 只负责落盘）
    while IFS='	' read -r _action _kind _dest _source _sha _extra; do
        [ "${_action:-}" = "rc" ] || continue
        _recorded=$(awk -F'\t' -v d="$_dest" '$1=="rc" && $3==d {v=$5} END{print v}' \
                    "$WTOOL_JOURNAL" 2>/dev/null || true)
        if [ -n "$_recorded" ] && [ "$_recorded" != "-" ] && \
           [ "$_extra" != "-" ] && [ "$_recorded" != "$_extra" ] && \
           [ "${WTOOL_FORCE:-0}" != 1 ]; then
            wt_die "rc 块已被改动: $_dest（记录 $_recorded，当前 $_extra）；--force 强行移除"
        fi
        wt_atomic_write "$_dest" "$_source"
        wt_step "rc    $_dest"
    done < "$_scratch/plan.tsv"

    # 1.5) plan 里剩下的动作（envblock-del 之类）。
    #      以前这里只手工处理了 rc 行，从没跑过 plan_exec ——
    #      新增的动作就这么被静默丢掉了，表现为"卸载完 loader 块还在"。
    if [ -s "$_scratch/plan.tsv" ]; then
        awk -F'\t' '$1 != "rc"' "$_scratch/plan.tsv" > "$_scratch/plan.rest.tsv" 2>/dev/null || true
        if [ -s "$_scratch/plan.rest.tsv" ]; then
            wt_plan_exec "$_scratch/plan.rest.tsv"
        fi
    fi

    # 2) 逆序回放 journal（安装时引擎做过什么，这里逆着做）
    if [ -f "$WTOOL_JOURNAL" ]; then
        wt_journal_reverse | while IFS='	' read -r _action _kind _dest _target _sha; do
            [ -z "${_action:-}" ] && continue
            case $_action in
                link)
                    _other=$(awk -F'\t' -v d="$_dest" '$1 == d {print $2; exit}' "$_claims" 2>/dev/null || true)
                    if [ -n "$_other" ]; then
                        # 还有别人要用：软链留着，登记改到那个项目名下
                        wt_info "保留 $_dest（项目 $_other 也声明了它）"
                        wt_registry_set "$_dest" "$_other" "$_kind"
                    else
                        wt_link_remove "$_dest" "$_target"
                        wt_registry_del "$_dest"
                    fi
                    ;;
                mkdir)
                    wt_remove_dir_if_empty "$_dest"
                    ;;
                backup)
                    if [ -e "$_target" ] && [ ! -e "$_dest" ]; then
                        wt_run mv -f -- "$_target" "$_dest"
                    fi
                    ;;
                rc) : ;;   # 已由上面的 rc 回退处理
                rccreate) : ;;   # 由第 5 步的全局收尾处理
                sysfile)
                    # 系统文件是 sudo-install 的地盘，这里**不动**它：
                    # uninstall 不越权（不还原 /etc，那是 sudo-uninstall 的事）
                    ;;
                srcdir)
                    # 源码树是构建缓存：清干净就删（有未提交改动则保留）
                    if [ -d "$_dest" ]; then
                        if [ -n "$(git -C "$_dest" status --porcelain 2>/dev/null)" ]; then
                            wt_warn "源码树有未提交改动，保留不删: $_dest"
                        else
                            wt_run rm -rf -- "$_dest"
                        fi
                    fi
                    ;;
            esac
        done
    fi
    rm -f -- "$_claims"

    # 3) 最后才让项目自己撤（§4.2：②' 拆 $HOME 软链 → ①' install.sh --uninstall）。
    #
    # 这一步原来在**最前面**，顺序是反的：项目脚本撤的是实体（大件），
    # 引擎拆的是指向那些实体的软链 —— 反过来的话，脚本可能已经找不到
    # 自己装的东西了。而且 install 现在是"先脚本后软链"，uninstall 逆着来
    # 才叫配对。
    if [ "${WTOOL_NO_SCRIPT:-0}" != 1 ] \
       && wt_project_script "$WTOOL_PROJECT_ROOT" install.sh >/dev/null 2>&1; then
        wt_info "项目脚本: install.sh --uninstall"
        if ! wt_run_project_script "$WTOOL_PROJECT_ROOT" install.sh --uninstall; then
            if [ "${WTOOL_FORCE:-0}" = 1 ]; then
                wt_warn "  install.sh --uninstall 失败（--force 继续）"
            else
                wt_die "install.sh --uninstall 失败；加 --force 强行继续"
            fi
        fi
    fi

    # 4) 清理引擎自己的空目录
    #    多个项目共享 wtool-work-dir/links 这类父目录，各自 journal 清不干净，
    #    这里统一做一次"只删空目录"的收尾。
    #    ⚠️ 只动 wtool-work-dir（引擎自用那一格），绝不碰 .wtool/usr 和影子 $HOME 的其它行。
    if ! wt_dry; then
        _work="$WTOOL_HOME/.wtool/wtool-work-dir"
        if [ -d "$_work" ]; then
            find "$_work" -depth -type d -empty -delete 2>/dev/null || true
        fi
        rmdir -- "$WTOOL_HOME/.wtool" 2>/dev/null || true
    fi

    # 4.5) 重算环境变量汇总。必须在第 5 步之前：
    #      最后一个项目卸载完时，汇总文件要消失、loader 块要从 rc 里剥掉，
    #      剥完 rc 才可能变成空文件，第 5 步才有东西可删。
    #      把"正在撤的这个项目"排除掉 —— 它的 state 目录到第 6 步才删，
    #      不排除的话 ~/usr 这条全局软链永远等不到"一个项目都不剩"。
    wt_env_sync "$WTOOL_PROJECT_ID"

    # 5) 收尾：当初由 wtool 创建的 rc 文件，如果现在已经空了就删掉
    #    （必须放在最后：只有最后一个项目卸载完，共享的 ~/.zshrc 才会变空）
    _created="$WTOOL_STATE/created-rc.tsv"
    if [ -f "$_created" ] && ! wt_dry; then
        _keep=""
        while IFS= read -r _f; do
            [ -n "$_f" ] || continue
            if [ -f "$_f" ] && [ -z "$(tr -d '[:space:]' < "$_f" 2>/dev/null)" ]; then
                rm -f -- "$_f"
                wt_step "删除空的 rc 文件 $_f"
            else
                _keep="$_keep$_f
"
            fi
        done < "$_created"
        if [ -n "$_keep" ]; then
            printf '%s' "$_keep" > "$_created"
        else
            rm -f -- "$_created"
        fi
    fi

    # 6) 清理状态目录。**只删 install 自己的账**：
    #    系统层的账（system.tsv、system/ 备份、apt.tsv、provisioned/ marker）
    #    留着 —— 那归 sudo-uninstall 管（不越权，也不越俎代庖）。
    if ! wt_dry; then
        for _f in meta.tsv journal.tsv env.zsh env.bash artifacts.tsv \
                  actions.tsv publish.tsv; do
            [ -e "$WTOOL_PROJECT_DIR/$_f" ] && rm -f -- "$WTOOL_PROJECT_DIR/$_f"
        done
        rmdir -- "$WTOOL_PROJECT_DIR" 2>/dev/null || true
        _p=$(dirname -- "$WTOOL_PROJECT_DIR")
        while [ "$_p" != "$WTOOL_STATE" ] && [ -d "$_p" ] \
              && [ -z "$(ls -A -- "$_p" 2>/dev/null)" ]; do
            rmdir -- "$_p" 2>/dev/null || break
            _p=$(dirname -- "$_p")
        done
        # registry 空了就删掉；state 目录空了也删掉，做到"装完卸完不留痕"
        if [ -f "$WTOOL_REGISTRY" ] && [ ! -s "$WTOOL_REGISTRY" ]; then
            rm -f -- "$WTOOL_REGISTRY"
        fi
        if [ -d "$WTOOL_STATE" ] && [ -z "$(ls -A -- "$WTOOL_STATE" 2>/dev/null)" ]; then
            rmdir -- "$WTOOL_STATE" 2>/dev/null || true
        fi
    fi
    wt_info "uninstall 完成"
}

# --------------------------------------------------------------------------
# sudo-install：系统层 —— /etc 下的文件 + 要跑的脚本/playbook + apt 包
#
# 和 install 完全分离（§0 那条铁律）：
#   * 要 sudo 的都叫 sudo-*；sudo-install 永不碰 $HOME 里的软链
#   * 可逆的（/etc 下的系统文件）记 journal，sudo-uninstall 还原
#   * 不可逆的（apt 包、编译产物）只记 marker 和 **apt 差集**
#     —— 差集就是"这次新装进来的包"，sudo-uninstall 只卸这些
# --------------------------------------------------------------------------
wt_when_match() {
    _when=$1
    [ -z "$_when" ] && return 0
    for _c in $(printf '%s' "$_when" | tr ',' ' '); do
        case $_c in
            os:*)    [ "$WTOOL_OS_ID" = "${_c#os:}" ] || return 1 ;;
            '!os:'*) [ "$WTOOL_OS_ID" != "${_c#!os:}" ] || return 1 ;;
            arch:*)  [ "$WTOOL_ARCH" = "${_c#arch:}" ] || return 1 ;;
            env:*)
                eval "_v=\${${_c#env:}:-}"
                case $(printf '%s' "$_v" | tr 'A-Z' 'a-z') in
                    ""|0|false|no) return 1 ;;
                esac ;;
            *)       wt_warn "未知 when 条件，按不匹配处理: $_c"; return 1 ;;
        esac
    done
    return 0
}

cmd_sudo_install() {
    _targets=""
    for arg in "$@"; do
        case $arg in
            --dry-run)     WTOOL_DRY_RUN=1 ;;
            --force)       WTOOL_FORCE=1 ;;
            --with-system) wt_die "--with-system 已经删掉：sudo-install 本来就是系统层。
用户层用 wtool install —— 两条命令永不互相调用。" ;;
            --no-system)   wt_die "--no-system 已经删掉：那正是 sudo-install 不做的事（它只管系统层）" ;;
            -*)            wt_die "未知参数: $arg" ;;
            *)             _targets="$_targets $arg" ;;
        esac
    done

    if [ -z "$_targets" ]; then
        wt_info "这些项目声明了 <sudo-install>（系统层）："
        _n=0
        while IFS='	' read -r _prio _pid _path; do
            [ -n "${_pid:-}" ] || continue
            wt_step "$_pid"
            _n=$((_n + 1))
        done <<EOF
$(python3 "$PY" sudo-list --root "$WTOOL_ROOT")
EOF
        [ "$_n" -gt 0 ] || wt_info "  （一个都没有）"
        wt_info "装其中一个：wtool sudo-install <项目>；全部：wtool sudo-bootstrap"
        return 0
    fi

    _targets=$(wt_expand_targets sudo $_targets)
    [ -n "$(printf '%s' "$_targets" | tr -d ' ')" ] || wt_die "没有匹配的项目（试试 wtool sudo-install 看有哪些）"

    for _want in $_targets; do
        _row=$(wt_resolve_project "$_want") || exit $?
        _pid=$(printf '%s\n' "$_row" | cut -f2)
        _path=$(printf '%s\n' "$_row" | cut -f3)
        _common=""
        [ "$WTOOL_FORCE" = 1 ] && _common="--force"
        [ "$WTOOL_DRY_RUN" = 1 ] && _common="$_common --dry-run"
        # shellcheck disable=SC2086
        wt_sudo_install_one "$_path" "$_pid" $_common || exit $?
    done
    # shellcheck disable=SC2086
    [ -n "${_SI_SCRATCHES:-}" ] && rm -rf -- $_SI_SCRATCHES
    return 0
}

# 一个项目的系统层动作：system-file → source → task（顺序固定）
wt_sudo_install_one() {   # <项目目录> <项目 id> [--dry-run] [--force]
    _si_dir=$1; _si_pid=$2; shift 2
    for arg in "$@"; do
        case $arg in
            --dry-run) WTOOL_DRY_RUN=1 ;;
            --force)   WTOOL_FORCE=1 ;;
        esac
    done

    _scratch=$(mktemp -d "${TMPDIR:-/tmp}/wtool.XXXXXX")
    # 清理交给调用方（cmd_sudo_install / cmd_sudo_bootstrap）——
    # trap 是进程级的，在循环里每次覆盖上一个，前面那些临时目录就漏了。
    _SI_SCRATCHES="${_SI_SCRATCHES:-} $_scratch"

    wt_info "── $_si_pid  系统层"
    python3 "$PY" plan-provision "$_si_dir" \
        --home "$WTOOL_HOME" --state "$WTOOL_STATE" --scratch "$_scratch" \
        --os-id "$WTOOL_OS_ID" --os-version "$WTOOL_OS_VERSION" \
        --os-codename "$WTOOL_OS_CODENAME" --arch "$WTOOL_ARCH" \
        --jobs "$WTOOL_JOBS" --prefix "$WTOOL_PREFIX" --src-root "$WTOOL_SRC" \
        $([ "$WTOOL_FORCE" = 1 ] && echo --force) || exit $?

    wt_load_project "$_scratch"

    # apt 差集：跑之前取一次已装包快照，跑完再取一次，差就是"这次的账"
    _si_apt_before=""
    if [ -s "$_scratch/tasks.tsv" ]; then
        if wt_apt_snapshot > "$_scratch/apt.before" 2>/dev/null; then
            _si_apt_before="$_scratch/apt.before"
        fi
    fi

    # 1) 系统文件（/etc 下）：可逆，备份三份 + 记 system.tsv。
    #    **不再需要 --with-system** —— sudo-install 本来就是系统层。
    if [ -s "$_scratch/sysfiles.tsv" ]; then
        while IFS='	' read -r _mode _dest _content _sha _bak _desc; do
            [ -z "${_mode:-}" ] && continue
            wt_info "系统文件[$_mode]: $_dest  ${_desc:+(${_desc})}"
            wt_sysfile_apply "$_mode" "$_dest" "$_content" "$_sha" "$_bak" "$_desc"
        done < "$_scratch/sysfiles.tsv"
    fi

    # 2) source：拉上游源码、固定 ref、建/重置分支、铺 overlay
    if [ -s "$_scratch/sources.tsv" ]; then
        while IFS='	' read -r _dir _url _ref _branch _overlay; do
            [ -z "${_dir:-}" ] && continue
            wt_info "source: $_url @ $_ref"
            wt_source_sync "$_dir" "$_url" "$_ref" "$_branch" "$_overlay"
        done < "$_scratch/sources.tsv"
    fi

    # 3) task：ansible / shell
    if [ -s "$_scratch/tasks.tsv" ]; then
        while IFS='	' read -r _runner _src _marker _desc _when; do
            [ -z "${_runner:-}" ] && continue
            if ! wt_when_match "$_when"; then
                wt_info "when=$_when 不匹配，跳过: $_desc"
                continue
            fi
            wt_info "task[$_runner]: $_desc"
            wt_task_run "$_runner" "$_src" "$_marker" "$_desc" \
                "${WTOOL_SOURCE_DIR:-$WTOOL_PROJECT_ROOT}"
        done < "$_scratch/tasks.tsv"
    fi

    if [ -n "$_si_apt_before" ] && ! wt_dry; then
        wt_apt_snapshot > "$_scratch/apt.after" 2>/dev/null || : > "$_scratch/apt.after"
        wt_apt_record_new "$WTOOL_PROJECT_ID" "$_si_apt_before" "$_scratch/apt.after"
    fi

    wt_info "sudo-install 完成: $_si_pid"
}

# --------------------------------------------------------------------------
# sudo-uninstall：撤系统层 —— /etc 还原 + 卸掉这次装进来的 apt 包
#
# **不越权**：它只碰 sudo-install 做过的事，$HOME 里的软链一个字都不动
# （那是 wtool uninstall 的事）。
# --------------------------------------------------------------------------
cmd_sudo_uninstall() {
    _targets=""
    _ids=""
    while [ $# -gt 0 ]; do
        case $1 in
            --dry-run) WTOOL_DRY_RUN=1 ;;
            --force)   WTOOL_FORCE=1 ;;
            --id)      shift; _ids="$_ids ${1:-}" ;;
            -*)        wt_die "未知参数: $1" ;;
            *)         _targets="$_targets $1" ;;
        esac
        shift
    done

    if [ -z "$_targets" ] && [ -z "$_ids" ]; then
        wt_info "这些项目在 state 里有系统层的记录："
        _n=0
        for _d in "$WTOOL_STATE"/*; do
            [ -d "$_d" ] || continue
            _b=$(basename -- "$_d")
            if [ -d "$_d/system" ] || [ -d "$_d/provisioned" ] || [ -f "$_d/apt.tsv" ]; then
                wt_step "$_b"
                _n=$((_n + 1))
            fi
        done
        [ "$_n" -gt 0 ] || wt_info "  （一个都没有）"
        wt_info "撤其中一个：wtool sudo-uninstall <项目>；全部：wtool sudo-uninstall all"
        return 0
    fi

    if [ -n "$_targets" ]; then
        _want_all=0
        for _want in $_targets; do
            [ "$_want" = "all" ] && _want_all=1
        done
        if [ "$_want_all" = 1 ]; then
            # `all` 按 **state 里剩下的账**认，不按项目表认：
            # 系统层装过什么只有 system.tsv / apt.tsv / provisioned 知道，
            # 而项目清单可能早就改了、甚至项目目录都不在了。
            _ids="$_ids $(wt_sudo_ids)"
        fi
        _targets=$(wt_expand_targets sudo $_targets)
        for _want in $_targets; do
            [ "$_want" = "all" ] && continue
            _row=$(wt_resolve_project "$_want") || exit $?
            _ids="$_ids $(printf '%s\n' "$_row" | cut -f2)"
        done
    fi

    for _id in $_ids; do
        [ -n "$_id" ] || continue
        wt_sudo_uninstall_one "$_id"
    done
    wt_info "sudo-uninstall 完成"
}

wt_sudo_uninstall_one() {   # <项目 id>
    _su_id=$1
    _su_dir="$WTOOL_STATE/$_su_id"
    if [ ! -d "$_su_dir" ]; then
        wt_warn "state 里没有 $_su_id（没跑过 sudo-install？）"
        return 0
    fi

    # 1) /etc 还原：依据是 system.tsv（系统层自己的账）。
    #    它**不会被 `wtool uninstall` 删掉** —— 两层各有各的账；
    #    uninstall 把它删了，sudo-uninstall 就再也没依据还原了。
    _su_r="$_su_dir/system.tsv"
    if [ -s "$_su_r" ]; then
        while IFS='	' read -r _mode _dest _osha _nsha _desc; do
            [ -n "${_mode:-}" ] || continue
            wt_info "还原系统文件[$_mode]: $_dest  ${_desc:+(${_desc})}"
            wt_sysfile_restore "$_mode" "$_dest" "$_osha" "$_nsha"
        done < "$_su_r"
    elif [ -s "$_su_dir/journal.tsv" ]; then
        # 更早的版本把依据记在 journal 里（sysfile 模式 落点 备份 sha）
        grep -v '^#' "$_su_dir/journal.tsv" | awk -F'\t' '$1 == "sysfile"' | \
        while IFS='	' read -r _act _mode _dest _bak _sha; do
            [ -n "${_mode:-}" ] || continue
            wt_info "还原系统文件[$_mode]（老记录）: $_dest"
            wt_sysfile_restore "$_mode" "$_dest" "-" "$_sha"
        done
    fi

    # 2) apt：只卸"这次装进来的"（apt.tsv 就是那次快照的差集）
    wt_apt_remove_recorded "$_su_id"

    # 3) 账本 / marker / 备份：价值已经兑现（要么还原了，要么卸了）
    for _su_p in "$_su_dir/system.tsv" "$_su_dir/system" "$_su_dir/provisioned" \
                 "$_su_dir/apt.tsv" "$_su_dir/provision.log"; do
        [ -e "$_su_p" ] && wt_run rm -rf -- "$_su_p"
    done
    rmdir -- "$_su_dir" 2>/dev/null || true
    wt_info "sudo-uninstall 完成: $_su_id"
}

# --------------------------------------------------------------------------
# bootstrap：把工作区里所有 wtool 项目按 priority 依次 install
#
# **不做系统层**（那要 sudo、要联网，是 sudo-bootstrap 的事）：
# 这条命令永不 sudo、永不联网，失败原因只可能是"某个项目的声明或产物"。
# --------------------------------------------------------------------------
cmd_bootstrap() {
    for arg in "$@"; do
        case $arg in
            --dry-run)      WTOOL_DRY_RUN=1 ;;
            --force)        WTOOL_FORCE=1 ;;
            --with-system)  wt_die "--with-system 已经删掉：系统层请用 wtool sudo-bootstrap
（bootstrap 只做用户层，永不 sudo、永不联网）" ;;
            --no-system)    wt_die "--no-system 已经删掉：bootstrap 本来就不做系统层" ;;
            --install-only) wt_die "--install-only 已经删掉：bootstrap 现在就是 install-only" ;;
            -*)             wt_die "未知参数: $arg" ;;
            *)              wt_die "bootstrap 不接受位置参数: $arg" ;;
        esac
    done

    wt_info "扫描项目: $WTOOL_ROOT"
    _list=$(mktemp "${TMPDIR:-/tmp}/wtool-list.XXXXXX")
    python3 "$PY" list-projects --root "$WTOOL_ROOT" > "$_list" || {
        rm -f "$_list"; wt_die "扫描项目失败"; }

    if [ ! -s "$_list" ]; then
        rm -f "$_list"
        wt_die "在 $WTOOL_ROOT 下没找到任何 wtool.xml"
    fi

    # 第一遍：能直接装的装掉；需要先产出东西的留到后面。
    # bootstrap 只做"不需要用户决策"的那部分 ——
    # build 是小时级的，download 要联网取包，都不该由它替用户决定。
    _pending=$(mktemp "${TMPDIR:-/tmp}/wtool-pending.XXXXXX")
    : > "$_pending"

    while IFS='	' read -r _prio _pid _path; do
        [ -z "${_pid:-}" ] && continue
        printf '\n=== [%s] %s ===\n' "$_prio" "$_pid"

        _needs=""
        wt_project_script "$_path" build.sh >/dev/null 2>&1 && _needs="build"
        # 判据和 `wtool install` **完全一致**：只看 `output/` 里有没有东西。
        # ⚠️ 别把"做过 build / 下过包"也算进来：`download-release` 只把包放到
        #    `release/`，`output/` 还是空的 —— 那时候放行，紧接着 install 就会 die
        #    （实测：这两个判据不一致会让人看到"bootstrap 说能装、装的时候说没产物"）。
        _ready=0
        if [ -n "$_needs" ]; then
            [ -n "$(ls -A -- "$_path/output" 2>/dev/null)" ] && _ready=1
        fi

        if [ -n "$_needs" ] && [ "$_ready" = 0 ]; then
            wt_info "跳过：需要先 $_needs（bootstrap 不替你做这个决定）"
            printf '%s\t%s\n' "$_pid" "$_needs" >> "$_pending"
            continue
        fi

        _common=""
        [ "$WTOOL_FORCE" = 1 ] && _common="$_common --force"
        [ "$WTOOL_DRY_RUN" = 1 ] && _common="$_common --dry-run"
        # shellcheck disable=SC2086
        cmd_install "$_path" $_common || wt_die "install 失败: $_pid"
    done < "$_list"
    rm -f "$_list"

    # 第二遍：把"还剩什么、为什么剩"摆出来，决定权交回用户
    printf '\n'
    wt_info "=============================================="
    if [ -s "$_pending" ]; then
        _n=$(awk 'END {print NR}' "$_pending")
        wt_info "还有 $_n 个项目没装 —— 它们要先产出东西："
        printf '\n'
        while IFS='	' read -r _pid _needs; do
            printf '  %-40s 需要先 %s\n' "$_pid" "$_needs"
        done < "$_pending"
        printf '\n'
        wt_info "build 是小时级的，download 要联网取包 —— 这两种都不该由"
        wt_info "bootstrap 替你决定。看完上面的表，你自己选着跑："
        printf '\n'
        while IFS='	' read -r _pid _needs; do
            case $_needs in
                *download*) printf '    wtool download-release %s && wtool unpack-release %s\n' "$_pid" "$_pid" ;;
            esac
            case $_needs in
                *build*)    printf '    wtool build    %s\n' "$_pid" ;;
            esac
            printf '    wtool install  %s\n' "$_pid"
        done < "$_pending"
        printf '\n'
        wt_info "跑完上面的命令，再 wtool install 一次就装上了。"
    else
        wt_info "全部项目都装好了。"
    fi
    wt_info "=============================================="
    rm -f "$_pending"

    printf '\n'
    cmd_table --verbose
}

# --------------------------------------------------------------------------
# sudo-bootstrap：所有项目的**系统层**（= 逐个 sudo-install）
#
# 和 bootstrap 分开是有意的：这条要 sudo、要联网，失败原因在系统环境那一头；
# bootstrap 永不 sudo、永不联网，失败原因在某个项目的声明或产物那一头。
# 混成一条命令就分不清该修哪边（§1 那张表）。
# --------------------------------------------------------------------------
cmd_sudo_bootstrap() {
    for arg in "$@"; do
        case $arg in
            --dry-run) WTOOL_DRY_RUN=1 ;;
            --force)   WTOOL_FORCE=1 ;;
            -*)        wt_die "未知参数: $arg" ;;
            *)         wt_die "sudo-bootstrap 不接受位置参数: $arg" ;;
        esac
    done

    _list=$(mktemp "${TMPDIR:-/tmp}/wtool-sudo.XXXXXX")
    python3 "$PY" sudo-list --root "$WTOOL_ROOT" > "$_list" || {
        rm -f "$_list"; wt_die "扫描项目失败"; }
    if [ ! -s "$_list" ]; then
        rm -f "$_list"
        wt_info "没有任何项目声明 <sudo-install>，没什么可做的"
        return 0
    fi

    _n=0
    while IFS='	' read -r _prio _pid _path; do
        [ -z "${_pid:-}" ] && continue
        printf '\n=== [%s] %s ===\n' "$_prio" "$_pid"
        _common=""
        [ "$WTOOL_FORCE" = 1 ] && _common="$_common --force"
        [ "$WTOOL_DRY_RUN" = 1 ] && _common="$_common --dry-run"
        # shellcheck disable=SC2086
        wt_sudo_install_one "$_path" "$_pid" $_common || wt_die "sudo-install 失败: $_pid"
        _n=$((_n + 1))
    done < "$_list"
    rm -f "$_list"
    # shellcheck disable=SC2086
    [ -n "${_SI_SCRATCHES:-}" ] && rm -rf -- $_SI_SCRATCHES
    wt_info "sudo-bootstrap 完成（$_n 个项目）"
}

# --------------------------------------------------------------------------
# pack-release：打包 → <项目>/release/
#
# 产出全部落在 release/：源码.zip、release.zip、（超 32M 就切分卷）、dist.json、
# 两个 -hash.txt，外加一个 `.source` 来源标记（`packed` / `downloaded` ——
# publish-release 靠它拒绝"把刚下下来的包又传回去"）。
# 另外往**项目目录里**写 docs/download.md（给人看的下载页，进 Git）。
#
# `scripts/release.json`（下载声明）**不在这里写** —— 它要等上传成功、
# base_url / published_at 定下来之后由 `publish-release` 写（ADR-026）。
#
# **不替你 commit**：跑完把该提交的打出来提醒。
# --------------------------------------------------------------------------
cmd_pack_release() {
    _targets=""
    _tag_override=""
    _repo_override=""
    _vol_override=""
    for arg in "$@"; do
        case $arg in
            --dry-run)        WTOOL_DRY_RUN=1 ;;
            --force)          WTOOL_FORCE=1 ;;
            --tag=*)          _tag_override=${arg#--tag=} ;;
            --repo=*)         _repo_override=${arg#--repo=} ;;
            --volume-size=*)  _vol_override=${arg#--volume-size=} ;;
            -*)               wt_die "未知参数: $arg" ;;
            *)                _targets="$_targets $arg" ;;
        esac
    done
    [ -n "$_targets" ] || wt_die "用法: wtool pack-release <项目>... [--tag=TAG] [--repo=owner/repo] [--volume-size=32M]

  产出落在 <项目>/release/：源码.zip、release.zip（大的切分卷）、dist.json、
  两个 -hash.txt、.source 来源标记；另外写 <项目>/docs/download.md"
    [ -n "$_vol_override" ] || _vol_override=${WTOOL_VOLUME_SIZE:-32M}

    _scratch=$(mktemp -d "${TMPDIR:-/tmp}/wtool-pack.XXXXXX")
    trap 'rm -rf -- "$_scratch"' EXIT INT TERM

    _done=0
    for _want in $_targets; do
        _row=$(wt_resolve_project "$_want") || exit $?
        _pid=$(printf '%s\n' "$_row" | cut -f2)
        _path=$(printf '%s\n' "$_row" | cut -f3)
        _tpl=$(printf '%s\n' "$_row" | cut -f6)

        if [ -n "$_tag_override" ]; then _tag=$_tag_override; else _tag=$(wt_publish_tag "$_tpl"); fi
        if [ -n "$_repo_override" ]; then
            _repo=$_repo_override
        else
            _repo=$(wt_publish_repo_of "$_path") || wt_die "$_pid 没有可用的 git remote，用 --repo=owner/repo 指定目标仓"
        fi

        wt_info "── $_pid"
        wt_info "  目标仓 : $_repo"
        wt_info "  tag    : $_tag"
        wt_info "  卷大小 : $_vol_override"
        wt_pack_release "$_path" "$_tag" "$_repo" "$_vol_override" "$_scratch" "$_pid"
        _done=$((_done + 1))
    done
    wt_info "pack-release 完成（$_done 个项目）"
}

# --------------------------------------------------------------------------
# unpack-release：按 dist.json 校验每卷 sha256 → 拼接 → 解开
#
# 只认 dist.json，**不需要任何项目特定知识**：
#   release 那一份解到项目根（里面有 output/ 和声明面 wtool.xml / env.zsh /
#   env.bash），源码包只校验不铺开。
# "解开"和"装"是两件事 —— 装是 wtool install 的事（这样才登记得进清单、卸得掉）。
# --------------------------------------------------------------------------
cmd_unpack_release() {
    _targets=""
    _from=""
    for arg in "$@"; do
        case $arg in
            --dry-run) WTOOL_DRY_RUN=1 ;;
            --from=*)  _from=${arg#--from=} ;;
            -*)        wt_die "未知参数: $arg" ;;
            *)         _targets="$_targets $arg" ;;
        esac
    done
    [ -n "$_targets" ] || wt_die "用法: wtool unpack-release <项目>... [--from=下载目录]

  默认从 <项目>/release/ 读 dist.json 和分卷；--from= 可以指到别处。" \
        ""
    [ -z "$_from" ] || _from=$(cd -- "$_from" && pwd) || wt_die "目录不存在: $_from"

    _scratch=$(mktemp -d "${TMPDIR:-/tmp}/wtool-unpack.XXXXXX")
    trap 'rm -rf -- "$_scratch"' EXIT INT TERM

    _done=0
    for _want in $_targets; do
        # 这里**不能**要求有 wtool.xml：unpack-release 的活正是"把声明面
        # （wtool.xml/env 文件）从包里解出来"，目标目录当然可能还没有它。
        # 所以目录路径直接认，只有给的是项目名时才去查项目表。
        _path=""
        case $_want in
            /*) [ -d "$_want" ] && _path=$(cd -- "$_want" && pwd) ;;
            *)  [ -d "$WTOOL_ROOT/$_want" ] && _path=$(cd -- "$WTOOL_ROOT/$_want" && pwd) ;;
        esac
        if [ -n "$_path" ]; then
            _pid=$(basename -- "$_path")
        else
            _row=$(wt_resolve_project "$_want") || exit $?
            _pid=$(printf '%s\n' "$_row" | cut -f2)
            _path=$(printf '%s\n' "$_row" | cut -f3)
        fi
        wt_info "── $_pid"
        if [ -n "$_from" ]; then
            wt_unpack_release "$_path" "$_scratch" "$_from"
        else
            wt_unpack_release "$_path" "$_scratch"
        fi
        # 改名（2026-09，release/ → output/）之前打的包，解开后顶层是 release/<target>/。
        # 这里顺手提示一句 —— 不然下一步 `wtool install` 只会说"output/ 是空的"，
        # 人会去重下几百兆，而其实只要 mv 一下。
        wt_check_old_dir_names "$_pid" "$_path"
        _done=$((_done + 1))
    done
    wt_info "unpack-release 完成（$_done 个项目）"
}

# 目录改名（2026-09）的迁移提示：老机器上还叫 release/ 和 publish/ 的目录。
#   publish/  →  release/    （打包发布产出）
#   release/  →  output/     （构建产出）
# **只 detect + 提示，不自动 mv**：目录名是用户的决定，而且现在可能有进程正在
# 往里写（build/download 跑一半），什么时候搬只有人知道。
# 旧 release/ 靠**形状**认：里面是 <os>_<ver>/<层>/；新的 release/ 是 *.zip + dist.json。
wt_check_old_dir_names() {   # <项目 id> <项目目录>（都为空 = 工作区里全部项目）
    _od_id=$1; _od_path=$2
    if [ -n "$_od_path" ]; then
        printf '%s\t%s\n' "${_od_id:-$_od_path}" "$_od_path"
    else
        python3 "$PY" publish-list --root "$WTOOL_ROOT" 2>/dev/null | cut -f2,3 || true
    fi | while IFS='	' read -r _od_pid _od_dir; do
        [ -n "${_od_dir:-}" ] || continue
        [ -d "$_od_dir" ] || continue
        _od_old_pub=0
        [ -d "$_od_dir/publish" ] && _od_old_pub=1
        # 旧 release/ 靠**形状**认：里面是 <os>_<ver>/<层>/；新的 release/ 是 *.zip + dist.json。
        _od_old_rel=0
        for _od_sub in "$_od_dir"/release/*/; do
            [ -d "$_od_sub" ] || continue
            case $(basename -- "$_od_sub") in
                *_*)   # ubuntu_24.04 / ubuntu_22.04 这种 = 旧的构建产出
                    _od_old_rel=1; break ;;
            esac
        done
        if [ "$_od_old_pub" = 1 ] && [ "$_od_old_rel" = 1 ]; then
            # 两个都在：**顺序不能反**，反了 mv publish release 会把 publish/ 塞进
            # 还是旧构建产出的 release/ 里，第二步再整个搬去 output/ —— 变成 output/publish/。
            wt_warn "[$_od_pid] 两个旧目录都在，按这个顺序搬（反了会把 publish/ 塞进 release/ 里）："
            wt_warn "  cd $_od_dir && mv release output && mv publish release"
        elif [ "$_od_old_pub" = 1 ]; then
            wt_warn "[$_od_pid] 旧目录名：publish/ 现在叫 release/，请 mv publish release"
        elif [ "$_od_old_rel" = 1 ]; then
            wt_warn "[$_od_pid] 这看起来是旧名字的构建产出，请 mv release output"
        fi
    done
}

# --------------------------------------------------------------------------
# check / repair：声明 / 日志 / 磁盘 三者对比
#   check  只报不改（有问题退出码 1）
#   repair 只重建、不删除（补软链、重写 rc 块、重建 ~/usr）
# --------------------------------------------------------------------------
cmd_check() {
    _args=""
    _project=""
    _project_id=""
    for arg in "$@"; do
        case $arg in
            --json) wt_die "--json 还没实现（现在只有人能读的表格输出）" ;;
            -*)     wt_die "未知参数: $arg" ;;
            *)      _project=$arg ;;
        esac
    done
    _project_id=""
    if [ -n "$_project" ]; then
        _row=$(wt_resolve_project "$_project") || exit $?
        _project_id=$(printf '%s\n' "$_row" | cut -f2)
        _project=$(printf '%s\n' "$_row" | cut -f3)
    fi
    _out=$(python3 "$PY" check --root "$WTOOL_ROOT" --home "$WTOOL_HOME" \
        --state "$WTOOL_STATE" ${_project:+"$_project"}) || _rc=$?
    _rc=${_rc:-0}
    # 迁移提示（不改退出码，也不进"修：wtool repair"那一类 —— repair 不搬目录）
    wt_check_old_dir_names "$_project_id" "$_project"
    if [ -n "$_out" ]; then
        printf '%s\n' "$_out" | while IFS='	' read -r _who _what; do
            if [ "$_who" = "-" ]; then
                printf 'wtool: [全局] %s\n' "$_what"
            else
                printf 'wtool: [%s] %s\n' "$_who" "$_what"
            fi
        done
        printf '\n'
        wt_warn "上面这些对不上（声明 / 日志 / 磁盘）。修：wtool repair"
        return 1
    fi
    wt_info "一切对得上（声明 / 日志 / 磁盘）"
    return 0
}

cmd_repair() {
    _targets=""
    for arg in "$@"; do
        case $arg in
            --dry-run) WTOOL_DRY_RUN=1 ;;
            -*)        wt_die "未知参数: $arg" ;;
            *)         _targets="$_targets $arg" ;;
        esac
    done
    if [ -z "$_targets" ]; then
        _targets="all"
    fi
    _targets=$(wt_expand_targets repair $_targets)
    [ -n "$(printf '%s' "$_targets" | tr -d ' ')" ] || wt_die "没有匹配的项目"

    # repair = 重跑一遍 install 的**引擎部分**：
    #   * 补中转链接、补 $HOME 软链、重写 env 块与汇总（plan-install 幂等）
    #   * 不跑项目自己的 install.sh（那可能重新编译/下载 —— repair 不猜你想干什么）
    #   * 永不删除：plan 里没有删除动作，只重建
    _n=0
    for _want in $_targets; do
        _row=$(wt_resolve_project "$_want") || exit $?
        _pid=$(printf '%s\n' "$_row" | cut -f2)
        _path=$(printf '%s\n' "$_row" | cut -f3)
        [ -d "$_path" ] || { wt_warn "$_pid 的目录不在磁盘上，跳过"; continue; }
        wt_info "── repair $_pid"
        _scratch=$(mktemp -d "${TMPDIR:-/tmp}/wtool-repair.XXXXXX")
        python3 "$PY" plan-install "$_path" \
            --home "$WTOOL_HOME" --state "$WTOOL_STATE" --scratch "$_scratch" \
            --head "-" --at "$(wt_now)" --force || {
            rm -rf -- "$_scratch"; wt_warn "$_pid 的清单有问题，跳过"; continue; }
        wt_load_project "$_scratch"
        wt_plan_exec "$_scratch/plan.tsv"
        wt_plan_exec "$_scratch/plan.home.tsv"
        rm -rf -- "$_scratch"
        _n=$((_n + 1))
    done
    wt_env_sync
    if wt_dry; then
        wt_info "repair 计划完成（$_n 个项目）"
    else
        wt_info "repair 完成（$_n 个项目；只重建，没删任何东西）"
    fi
}

# --------------------------------------------------------------------------
# kill-self-forever：删掉 wtool 的一切痕迹（**不可逆**）
#
# 要求逐字输入一句全大写确认（照抄 GitHub 删仓库的做法），
# 并且先把"删什么、不删什么"一条条列清楚：这个命令的破坏力要求
# 用户在按回车之前就知道自己在做什么。
# --------------------------------------------------------------------------
wt_kill_confirm_word="KILL-SELF-FOREVER"

cmd_kill_self_forever() {
    _yes=0
    for arg in "$@"; do
        case $arg in
            --yes) _yes=1 ;;
            --dry-run) WTOOL_DRY_RUN=1 ;;
            -*) wt_die "未知参数: $arg（用法: wtool kill-self-forever [--dry-run]）" ;;
            *)  wt_die "不接受位置参数: $arg" ;;
        esac
    done

    _scratch=$(mktemp -d "${TMPDIR:-/tmp}/wtool-kill.XXXXXX")
    trap 'rm -rf -- "$_scratch"' EXIT INT TERM
    python3 "$PY" kill-plan --home "$WTOOL_HOME" --state "$WTOOL_STATE" \
        > "$_scratch/kill.tsv" || wt_die "算不出要删什么"

    _nlink=$(awk -F'\t' '$1=="link"{n++} END{print n+0}' "$_scratch/kill.tsv")

    printf '\n'
    wt_info "kill-self-forever 会删掉下面这些（**不可逆**）："
    printf '\n'
    printf '  【$HOME 里的软链】%s 条，都是 wtool 自己建的（只删还指向 wtool 的）\n' "$_nlink"
    awk -F'\t' '$1=="link"{printf "      %s\n", $2}' "$_scratch/kill.tsv" | head -20
    [ "$_nlink" -gt 20 ] && printf '      …（还有 %s 条）\n' "$((_nlink - 20))"
    printf '\n'
    printf '  【影子 HOME】%s\n' "$WTOOL_HOME/.wtool"
    printf '      （编译产物 ~/.wtool/usr、自举副本 ~/.wtool/bootstrap、\n'
    printf '        所有项目的 env 汇总都在这里，一起没）\n'
    printf '  【状态目录】%s\n' "$WTOOL_STATE"
    printf '      （装过什么、怎么撤的记录；删了就只能靠手工收拾）\n'
    printf '  【rc 里的 loader 块】%s\n' "$WTOOL_HOME/.zshrc 和 $WTOOL_HOME/.bashrc 里 # >>> wtool >>> 那一段"
    printf '\n'
    wt_info "**不删**下面这些（它们不归 wtool 管）："
    printf '\n'
    printf '  * apt 包和 /etc 下的改动 —— 那是 sudo 装的，用 wtool sudo-uninstall all 撤\n'
    printf '  * 项目仓库本身（工作区里的源码一个字节都不动）\n'
    printf '  * 你自己手工建的东西 / 你自己的 rc 内容\n'
    printf '  * 引擎本体：%s（它是工作区里的源码，删它请自己 rm -rf）\n' "$WTOOL_BOOTSTRAP"
    printf '\n'

    if [ "$_yes" != 1 ]; then
        printf '确认要删，请逐字输入 %s：' "$wt_kill_confirm_word"
        _ans=""
        if [ -t 0 ]; then
            read -r _ans || _ans=""
        else
            read -r _ans || _ans=""
        fi
        if [ "$_ans" != "$wt_kill_confirm_word" ]; then
            wt_info "输入不匹配，什么都没做"
            return 1
        fi
    else
        wt_warn "--yes：跳过确认（脚本里用；出事自己负责）"
    fi

    if wt_dry; then
        wt_info "[dry-run] 上面这些都会被删（现在什么都没动）"
        return 0
    fi

    # 1) 软链（只删还指向原位的）
    wt_kill_links < "$_scratch/kill.tsv"
    # 2) 影子 HOME 和状态目录
    wt_kill_paths < "$_scratch/kill.tsv"
    # 3) rc 里的 loader 块：把 state 指到一个**空目录**再算一遍。
    #    不能直接用真的 state：wt_env_sync 里的记账会 mkdir 它，
    #    于是"删干净"之后 state 又冒出来了（踩过）。
    _kill_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wtool-kill-state.XXXXXX")
    ( WTOOL_STATE="$_kill_tmp" wt_env_sync )
    rm -rf -- "$_kill_tmp"
    wt_info "wtool 的痕迹已经删干净了"
    wt_info "（sudo 装的那些还在，要撤：wtool sudo-uninstall all）"
}

cmd_status() {
    if [ $# -gt 0 ]; then
        _id=$(python3 "$PY" validate "$1" --home "$WTOOL_HOME" --state "$WTOOL_STATE" \
              >/dev/null 2>&1 && echo ok || echo fail)
        [ "$_id" = ok ] || { wt_warn "清单校验失败: $1"; return 1; }
    fi
    # ① 软链检查
    _bad=0
    _n=0
    if [ -f "$WTOOL_REGISTRY" ]; then
        while IFS='	' read -r _dest _id _kind; do
            [ -z "${_dest:-}" ] && continue
            _n=$((_n + 1))
            if [ ! -L "$_dest" ]; then
                wt_warn "缺失: $_dest（项目 $_id）"
                _bad=$((_bad + 1))
            fi
        done < "$WTOOL_REGISTRY"
    fi
    [ "$_bad" -eq 0 ] && wt_info "所有登记的软链都在（$_n 条）"

    # ② 登记表（原来 `wtool list` 的那张，2026-09 并进 status）
    printf '\n'
    if [ "$_n" -eq 0 ]; then
        wt_info "（registry 为空 —— 还没装过任何项目）"
        return 0
    fi
    printf '%-12s %-8s %s\n' PROJECT KIND DEST
    awk -F'\t' '{printf "%-12s %-8s %s\n", $2, $3, $1}' "$WTOOL_REGISTRY"
    return 0
}

cmd_doctor() {
    # --quiet/--json：只要环境变量那一批 export 行，别的什么都不印。
    # 这条路径要能直接 eval：
    #     eval "$(wtool doctor --quiet)"
    # 所以它**一个诊断行都不能有** —— 混进去的话 eval 会去执行
    # "wtool: engine : 1.0.0" 这种句子。
    _env_only=0
    for _a in "$@"; do
        case $_a in
            --quiet|-q|--json) _env_only=1 ;;
        esac
    done
    if [ "$_env_only" = 1 ]; then
        cmd_env "$@"
        return 0
    fi

    wt_info "engine      : $ENGINE_VERSION"
    wt_info "bootstrap   : $WTOOL_BOOTSTRAP"
    wt_info "root        : $WTOOL_ROOT"
    wt_info "home        : $WTOOL_HOME"
    wt_info "state       : $WTOOL_STATE"
    wt_info "prefix      : $WTOOL_PREFIX  (编译安装前缀)"
    wt_info "os          : $WTOOL_OS_ID $WTOOL_OS_VERSION ($WTOOL_OS_CODENAME) like=$WTOOL_OS_LIKE"
    wt_info "arch/jobs   : $WTOOL_ARCH / $WTOOL_JOBS"
    wt_info "python3     : $(python3 --version 2>&1 || echo '缺失')"
    wt_info "git         : $(git --version 2>&1 || echo '缺失')"
    _n=0
    [ -f "$WTOOL_REGISTRY" ] && _n=$(grep -c . "$WTOOL_REGISTRY" 2>/dev/null || echo 0)
    wt_info "registered  : $_n 条"
    _uk="$WTOOL_HOME/usr"
    if [ -L "$_uk" ]; then
        wt_info "~/usr       : $(readlink -- "$_uk")"
    elif [ -e "$_uk" ]; then
        wt_warn "~/usr       : 存在但不是软链（应该是 → ~/.wtool/usr）"
    else
        wt_info "~/usr       : 还没有（装第一个项目时由引擎建）"
    fi

    # 环境变量（原来 `wtool env` 的那份，2026-09 并进 doctor）
    printf '\n'
    cmd_env
    printf '\n'
    cmd_table --verbose --summary
}

# --------------------------------------------------------------------------
# wtool table —— 一行一个项目，一列一个能力
#
#   不支持 / 可执行 / 待产出 / 已完成 —— 四种状态是**中文词**不是符号
#   （常量在 lib/wtool_plan.py:1366-1376，颜色只是辅助）。
#   早先用的是 ASCII `+ - .` 三个符号，已经废弃：符号要靠图例才看得懂，
#   而"没这项能力"和"有能力但还没做"用一个 `.` 表示会混。
# --------------------------------------------------------------------------
cmd_table() {
    _args=""
    for _a in "$@"; do
        case $_a in
            --verbose|-v) _args="$_args --verbose" ;;
            --summary|-s) _args="$_args --summary" ;;
            --color=*)    _args="$_args --color=${_a#--color=}" ;;
            -*) wt_die "未知参数: $_a（可用 --verbose --summary）" ;;
            *)  wt_die "table 不接受位置参数: $_a" ;;
        esac
    done
    # shellcheck disable=SC2086
    python3 "$PY" table --root "$WTOOL_ROOT" --state "$WTOOL_STATE" $_args
    echo
    _c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
    printf '  %s  这个项目没这项能力\n' "$(_c 31 不支持)"
    printf '  %s  现在就能跑\n' "$(_c 33 可执行)"
    printf '  %s  能力有，但要先把 output/ 产出来\n' "$(_c 34 待产出)"
    printf '  %s  跑过了\n' "$(_c 32 已完成)"
    printf '\n  流水线：产出 → install，前面的没做后面的跑不起来。\n'
    printf '  产出有两条路：wtool build，或者 wtool download-release + wtool unpack-release。\n'
    printf '  前置没做时 install 会直接报错告诉你去跑哪条，不会替你跑。\n'
    printf '  （发布和下载不是"项目能力"，是引擎统一做的 —— 见 harness/docs/adr/0023。）\n'
}

# --------------------------------------------------------------------------
# wtool env —— 直接输出可用的环境变量（带中文说明）
#
#   eval "$(wtool.sh env)"      当前 shell 立即生效
#   wtool.sh env > ~/.wtool.env 然后自己 source
#   wtool.sh env --quiet        只要 export 行，不要注释
#   wtool.sh env --json         给脚本/程序用
# --------------------------------------------------------------------------
cmd_env() {
    _quiet=0
    _json=0
    for _a in "$@"; do
        case $_a in
            --quiet|-q) _quiet=1 ;;
            --json)     _json=1 ;;
            *) wt_die "未知参数: $_a" ;;
        esac
    done

    if [ "$_json" = 1 ]; then
        cat <<EOF
{
  "WTOOL_BOOTSTRAP": "$WTOOL_BOOTSTRAP",
  "WTOOL_ROOT": "$WTOOL_ROOT",
  "WTOOL_HOME": "$WTOOL_HOME",
  "WTOOL_STATE": "$WTOOL_STATE",
  "WTOOL_PREFIX": "$WTOOL_PREFIX",
  "WTOOL_OS_ID": "$WTOOL_OS_ID",
  "WTOOL_OS_VERSION": "$WTOOL_OS_VERSION",
  "WTOOL_OS_CODENAME": "$WTOOL_OS_CODENAME",
  "WTOOL_OS_LIKE": "$WTOOL_OS_LIKE",
  "WTOOL_ARCH": "$WTOOL_ARCH",
  "WTOOL_JOBS": "$WTOOL_JOBS"
}
EOF
        return 0
    fi

    _c() { [ "$_quiet" = 1 ] && return 0; printf '%s\n' "$1"; }

    _c "# wtool 环境变量 —— 由 \`wtool doctor\` 生成（原来那条 wtool env 已经并进来）"
    _c "# 立即生效： eval \"\$(wtool doctor --quiet)\""
    _c "# 长期生效： 装 bootstrap 项目（cd bootstrap && ./install.sh），它会自动导出这些"
    _c ""
    _c "# ── wtool 自身的位置 ──────────────────────────────"
    _c "# 引擎所在目录（含 wtool.sh / lib / templates）"
    printf 'export WTOOL_BOOTSTRAP=%s\n' "$(_q "$WTOOL_BOOTSTRAP")"
    _c "# 整个 wtool 集合的根目录（repo 工作区）"
    printf 'export WTOOL_ROOT=%s\n' "$(_q "$WTOOL_ROOT")"
    _c "# 被管理的家目录"
    printf 'export WTOOL_HOME=%s\n' "$(_q "$WTOOL_HOME")"
    _c "# 状态目录：registry.tsv / 每个项目的 journal.tsv 和 meta.tsv"
    printf 'export WTOOL_STATE=%s\n' "$(_q "$WTOOL_STATE")"
    _c ""
    _c "# ── 编译安装前缀 ──────────────────────────────────"
    _c "# wsw.sh / provision 只准往这里装；想卸载就删掉这里对应的文件"
    printf 'export WTOOL_PREFIX=%s\n' "$(_q "$WTOOL_PREFIX")"
    _c ""
    _c "# ── 当前系统信息（来自 /etc/os-release 与 uname）──"
    _c "# 发行版 ID：ubuntu / debian / rocky / centos / rhel / fedora ..."
    printf 'export WTOOL_OS_ID=%s\n' "$(_q "$WTOOL_OS_ID")"
    _c "# 版本号：如 24.04"
    printf 'export WTOOL_OS_VERSION=%s\n' "$(_q "$WTOOL_OS_VERSION")"
    _c "# 代号：如 noble（非 Debian 系可能为空）"
    printf 'export WTOOL_OS_CODENAME=%s\n' "$(_q "$WTOOL_OS_CODENAME")"
    _c "# 上游家族：如 debian / \"rhel centos fedora\""
    printf 'export WTOOL_OS_LIKE=%s\n' "$(_q "$WTOOL_OS_LIKE")"
    _c "# CPU 架构：x86_64 / aarch64 ..."
    printf 'export WTOOL_ARCH=%s\n' "$(_q "$WTOOL_ARCH")"
    _c "# 并行编译任务数（nproc）"
    printf 'export WTOOL_JOBS=%s\n' "$(_q "$WTOOL_JOBS")"
    _c ""
    _c "# ── PATH / 动态库路径 ─────────────────────────────"
    _c "# 让编译安装的二进制和 wtool 命令可直接调用"
    printf 'export PATH="%s/bin:%s/bin:$PATH"\n' \
        "$WTOOL_PREFIX" "$WTOOL_BOOTSTRAP"
    _c "# 让编译安装的库能被找到（ldconfig 之外的兜底）"
    printf 'export LD_LIBRARY_PATH="%s/lib:%s/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' \
        "$WTOOL_PREFIX" "$WTOOL_PREFIX"
}

# 给 shell 值加引号（只处理常见危险字符，够用）
_q() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# --------------------------------------------------------------------------
# init：新建一个 wtool 项目
#
# 目标是把「加一个项目」变成一条命令：目录、wtool.xml、env 文件、
# 以及三个可选脚本的模板都生成好，填空即可。
#
#   wtool init ./terminal/foo
#   wtool init ./terminal/foo --id terminal/foo --priority 55 --with-build
#
# 只生成**真的需要**的脚本：不需要构建就别要 build.sh —— 表格里那一列
# 是靠脚本存在与否点亮的，放一个空壳进去等于撒谎。
# --------------------------------------------------------------------------
cmd_init() {
    _dir=""; _id=""; _prio=""
    _with_build=0; _with_install=0
    while [ $# -gt 0 ]; do
        case $1 in
            --id)           shift; _id=${1:-} ;;
            --priority)     shift; _prio=${1:-} ;;
            --with-build)   _with_build=1 ;;
            --with-install) _with_install=1 ;;
            --with-publish|--with-download)
                            wt_die "$1 已经取消（ADR-023）：项目脚本只剩 build.sh 和 install.sh 两种；
  发布归引擎（pack-release + publish-release），下载归引擎（download-release + unpack-release）" ;;
            --all)          _with_build=1; _with_install=1 ;;
            -*)             wt_die "未知参数: $1" ;;
            *)              _dir=$1 ;;
        esac
        shift
    done
    [ -n "$_dir" ] || wt_die "用法: wtool.sh init <目录> [--id ID] [--priority N] [--all]

  --with-build    生成 scripts/build.sh（能编译 / 要产出的项目）
  --with-install  生成 scripts/install.sh（wtool.xml 表达不了的安装步骤）
  --all           两个都要

  （发布和下载**不用写脚本**：pack-release / publish-release / download-release /
    unpack-release 全是引擎命令，见 harness/docs/adr/0023。）

  纯声明式的项目（只靠 wtool.xml 的 link/env 就能装好）不需要任何脚本。"
    [ -n "$_prio" ] || _prio=100

    # id 默认取相对工作区的路径，这样嵌套项目也对
    _abs=$(cd -- "$(dirname -- "$_dir")" 2>/dev/null && pwd)/$(basename -- "$_dir") 2>/dev/null || _abs=$_dir
    if [ -z "$_id" ]; then
        _id=$(python3 -c '
import os, sys
p, root = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
rel = os.path.relpath(p, root)
print(os.path.basename(p) if rel.startswith("..") else rel)
' "$_abs" "$WTOOL_ROOT")
    fi
    case $_id in
        /*|*..*) wt_die "项目 id 非法: $_id" ;;
    esac

    mkdir -p -- "$_dir"

    if [ -f "$_dir/wtool.xml" ]; then
        wt_warn "wtool.xml 已存在，不动它: $_dir/wtool.xml"
    else
        cat > "$_dir/wtool.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!--
  $_id

  写清楚这个项目是干什么的，以及装完之后用户能用到什么。
  wtool 只认下面这些元素，别的不认识的会直接报错（x- 前缀也不例外 —— 没有自定义元素这回事）。
-->
<wtool schema="1" id="$_id" priority="$_prio">

  <!-- shell 集成：两个 shell 各一份，内容要等价（公司机器上没有 zsh 的多得很） -->
  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>

  <!-- 提供一个配置文件：三段映射（home= 和 subproject= 必填）
         home=        \$HOME 下的落点（写全，带 ~/）
         wtool=       影子 HOME（~/.wtool/）下的落点；省掉就按镜像路径推
         subproject=  项目里的相对路径（内容从这儿来）
       连起来：<项目>/foo.conf → ~/.wtool/.foo.conf → ~/.foo.conf
  <link home="~/.foo.conf" subproject="foo.conf"/>
  -->

  <!-- 目录、内容由项目自己的 install.sh 产出时，把 subproject 换成 produced-by：
  <link home="~/.config/foo" wtool="~/.wtool/.config/foo" produced-by="install.sh"/>
  -->

  <!-- 系统层（apt 包、/etc 下的文件、要跑的脚本）：**不在 install 里跑**
  <sudo-install src="provision/packages.yaml" marker="$_id-deps"/>
  -->

</wtool>
EOF
        wt_step "生成 wtool.xml"
    fi

    # env 两份必须同改：只写 zsh 的后果是"那个 shell 的用户敲命令 command not found"，
    # 而 rc 文件里看起来明明装过了 —— 这种半装状态最难查。
    for _sh in zsh bash; do
        if [ ! -f "$_dir/env.$_sh" ]; then
            cat > "$_dir/env.$_sh" <<'EOF'
# 被 shell 的 wtool 托管块 source。
# 加载器已经导出：WTOOL_PROJECT_ID / WTOOL_PROJECT_DIR / WTOOL_PROJECT_ROOT
#
# 这里放这个项目需要的环境变量，例如：
#   export PATH="$WTOOL_PROJECT_DIR/bin:$PATH"
#   export PATH="$WTOOL_PREFIX/bin:$PATH"   # 装出来的东西的 bin，最容易漏的就是这句
EOF
            wt_step "生成 env.$_sh"
        fi
    done

    _tpl_dir="$here/templates"
    mkdir -p -- "$_dir/scripts"
    _emit() {   # <脚本名> <说明>
        [ -f "$_dir/scripts/$1" ] && { wt_warn "scripts/$1 已存在，不动它"; return 0; }
        [ -f "$_tpl_dir/$1.tpl" ] || wt_die "缺少模板: $_tpl_dir/$1.tpl"
        sed "s|@PROJECT_ID@|$_id|g" "$_tpl_dir/$1.tpl" > "$_dir/scripts/$1"
        chmod +x -- "$_dir/scripts/$1"
        wt_step "生成 scripts/$1  ($2)"
    }
    [ "$_with_build" = 1 ]   && _emit build.sh   "能构建"
    [ "$_with_install" = 1 ] && _emit install.sh "能安装"

    wt_info "已生成项目: $_dir  (id=$_id priority=$_prio)"
    wt_info "下一步：填 wtool.xml，然后 wtool validate $_dir"
    wt_info "（动作脚本都在 scripts/ 下；不需要的脚本别留空壳——表格那一列靠它点亮）"
}

# --------------------------------------------------------------------------
# publish：把项目发布成 release 资产
#
# 行为由项目自己的 wtool.xml 决定：
#   **只上传**：打包是 pack-release 的事（ADR-023）。要传的东西必须已经在
#   <项目>/release/ 里，而且带 dist.json 与 .source=packed。
#
#   kind="source"（默认）  → 传到项目 origin 的 release（或 to= 指定的仓）
#   to="owner/repo"        → 推到别的仓
#   kind="none"            → 不发布（第三方上游仓）
#
# 源码包解压后与 repo sync 出来的路径完全一致，所以解压完 wtool 就能用。
# --------------------------------------------------------------------------

# 把用户给的项目名解析成一行完整的 publish-list 记录（7 列）。
# 支持：完整 id、"terminal/tmux"；id 末段、"tmux"；以及目录路径。
wt_publish_resolve() {
    _want=$1
    _abs=""
    case $_want in
        /*) [ -d "$_want" ] && _abs=$(cd -- "$_want" && pwd) ;;
        *)  [ -d "$WTOOL_ROOT/$_want" ] && _abs=$(cd -- "$WTOOL_ROOT/$_want" && pwd) ;;
    esac

    _all=$(python3 "$PY" publish-list --root "$WTOOL_ROOT") \
        || wt_die "读不出项目表（python3 $PY publish-list 失败）"
    _hits=""
    # 先按路径精确匹配（用户直接给了目录）
    if [ -n "$_abs" ]; then
        _hits=$(printf '%s\n' "$_all" | awk -F'\t' -v p="$_abs" '$3 == p')
    fi
    # 再按 id / id 末段匹配。
    # 用 substr 比尾部而不是 index——index 没找到时返回 0，若待匹配串长度
    # 正好等于 id 长度，右边的 0 会撞上，产生假匹配。
    if [ -z "$_hits" ]; then
        _hits=$(printf '%s\n' "$_all" | awk -F'\t' -v w="$_want" '
            $2 == w { print; next }
            length(w) < length($2) && substr($2, length($2) - length(w)) == "/" w { print; next }
        ')
    fi

    _n=$(printf '%s\n' "$_hits" | grep -c . || true)
    case $_n in
        0) wt_die "找不到项目: $_want（用 wtool publish-release 不带参数看全部）" ;;
        1) printf '%s\n' "$_hits" ;;
        *) wt_warn "「$_want」匹配到多个项目："
           printf '%s\n' "$_hits" | awk -F'\t' '{print "  " $2}' >&2
           wt_die "请写完整的项目 id" ;;
    esac
}

# 把用户给的项目名解析成一行完整的 7 列记录（和 publish-list 同格式）。
#
# 比 wt_publish_resolve 多认一样东西：**工作区外面的目录**。
# sudo-install / pack-release / check 这些命令拿的是"项目目录"，
# 测试和临时目录里的项目不在工作区里，也应该能直接指过来。
wt_resolve_project() {
    _rp_want=$1
    _rp_abs=""
    case $_rp_want in
        /*) [ -d "$_rp_want" ] && _rp_abs=$(cd -- "$_rp_want" && pwd) ;;
        *)  [ -d "$WTOOL_ROOT/$_rp_want" ] && _rp_abs=$(cd -- "$WTOOL_ROOT/$_rp_want" && pwd) ;;
    esac
    if [ -n "$_rp_abs" ] && [ -f "$_rp_abs/wtool.xml" ]; then
        _rp_info=$(python3 "$PY" publish-info "$_rp_abs" --root "$WTOOL_ROOT" 2>/dev/null) || true
        if [ -n "$_rp_info" ]; then
            _rp_prio=$(printf '%s\n' "$_rp_info" | awk -F'\t' '$1=="priority"{print $2}')
            _rp_pid=$(printf '%s\n' "$_rp_info" | awk -F'\t' '$1=="project_id"{print $2}')
            _rp_kind=$(printf '%s\n' "$_rp_info" | awk -F'\t' '$1=="kind"{print $2}')
            _rp_scr=$(printf '%s\n' "$_rp_info" | awk -F'\t' '$1=="script"{print $2}')
            _rp_tag=$(printf '%s\n' "$_rp_info" | awk -F'\t' '$1=="tag"{print $2}')
            _rp_to=$(printf '%s\n' "$_rp_info" | awk -F'\t' '$1=="to"{print $2}')
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "${_rp_prio:-100}" "$_rp_pid" "$_rp_abs" "${_rp_kind:-source}" \
                "${_rp_scr:--}" "${_rp_tag:-snapshot-%Y-%m-%d}" "${_rp_to:--}"
            return 0
        fi
    fi
    wt_publish_resolve "$_rp_want"
}

cmd_publish_release() {
    _want=""
    _tag_override=""
    _outdir=""
    for arg in "$@"; do
        case $arg in
            --dry-run)       WTOOL_DRY_RUN=1 ;;
            --force)         WTOOL_FORCE=1 ;;
            --allow-foreign) WTOOL_ALLOW_FOREIGN=1 ;;
            --tag=*)         _tag_override=${arg#--tag=} ;;
            --out=*)         _outdir=${arg#--out=} ;;
            -*)              wt_die "未知参数: $arg" ;;
            *)               _want="$_want $arg" ;;
        esac
    done

    command -v gh >/dev/null 2>&1 || wt_die "publish-release 需要 gh（GitHub CLI）；装好再试"

    if [ -n "$_outdir" ]; then
        mkdir -p -- "$_outdir" || wt_die "建不了目录: $_outdir"
        _outdir=$(cd -- "$_outdir" && pwd)
    fi
    _scratch=$(mktemp -d "${TMPDIR:-/tmp}/wtool-publish.XXXXXX")
    # 失败时别把产物一起删掉。
    # 踩过：构建跑满 30 分钟、产物 576M，上传到一半代理断线（EOF），
    # 然后 trap 把临时目录连产物一起清了 —— 想重试就得从头再编一遍。
    # 这里产物本来就住在项目的 release/ 里，所以只需要别删它。
    _cleanup_scratch() { rm -rf -- "$_scratch"; }
    trap '_cleanup_scratch' EXIT INT TERM

    # 1) 决定发布哪些项目
    : > "$_scratch/sel.tsv"
    if [ -n "$_want" ]; then
        for w in $_want; do
            wt_publish_resolve "$w" >> "$_scratch/sel.tsv" || exit $?
        done
        _tmp="$_scratch/sel.dedup"
        awk -F'\t' '!seen[$2]++' "$_scratch/sel.tsv" > "$_tmp" && mv -f "$_tmp" "$_scratch/sel.tsv"
    else
        python3 "$PY" publish-list --root "$WTOOL_ROOT" > "$_scratch/sel.tsv"
    fi

    if [ ! -s "$_scratch/sel.tsv" ]; then
        wt_die "没有任何项目声明了 publish"
    fi

    _done=0
    _failed=0
    # 清单走 fd 3，不走 stdin。脚本自己（或它调用的 docker/gh）读 stdin 是常事，
    # 从 stdin 读清单会被它们偷走行，表现是后面的项目被静默跳过。
    exec 3< "$_scratch/sel.tsv"
    while IFS='	' read -r _prio _pid _path _kind _script _tpl _to <&3; do
        [ -n "${_pid:-}" ] || continue
        _date=$(date +%Y-%m-%d)
        if [ -n "$_tag_override" ]; then _tag=$_tag_override; else _tag=$(wt_publish_tag "$_tpl"); fi

        wt_info "── $_pid"
        if [ "$_kind" = "none" ]; then
            wt_info "  声明为不发布，跳过"
            continue
        fi

        # 目标仓：<publish to="..."> 优先，否则取项目 remote
        if [ "$_to" != "-" ] && [ -n "$_to" ]; then
            _repo=$_to
        else
            _repo=$(wt_publish_repo_of "$_path") || {
                wt_warn "$_pid 没有可用的 git remote，跳过"
                continue
            }
        fi
        wt_info "  目标仓 : $_repo"
        wt_info "  tag    : $_tag"

        # 权限检查：第三方上游仓（neovim/neovim）在这里被挡下
        if [ "${WTOOL_ALLOW_FOREIGN:-0}" != 1 ]; then
            _rc=0
            _perm=$(wt_publish_can_push "$_repo") || _rc=$?
            if [ "$_rc" = 1 ]; then
                wt_warn "  没有 $_repo 的写权限（viewerPermission=$_perm）"
                wt_warn "  这是第三方仓。要发布请在 wtool.xml 写 <publish to=\"自己的仓\"/>，"
                wt_warn "  或者声明 kind=\"none\"。确实要试就加 --allow-foreign。"
                continue
            elif [ "$_rc" != 0 ]; then
                wt_warn "  查不到 $_repo（rc=$_rc），继续尝试"
            fi
        fi

        # 要传的东西：**必须是本地打出来的**（release/ 里那一份）
        _rel="$_path/release"
        if [ ! -f "$_rel/dist.json" ]; then
            wt_warn "  release/ 里没有 dist.json —— 先打包：wtool pack-release $_pid"
            _failed=$((_failed + 1))
            continue
        fi
        # 来源标记：刚 download-release 下来的包不许当自己的发出去（ADR-026）
        if [ -f "$_rel/.source" ] && \
           [ "$(cut -f1 < "$_rel/.source" 2>/dev/null)" = "downloaded" ]; then
            wt_warn "  release/ 里是**下载来的**包（$(cut -f2,3 < "$_rel/.source" 2>/dev/null | tr '\t' ' ')）"
            wt_warn "  不能把别人打的包当自己的发出去。要发自己这一版：wtool pack-release $_pid"
            _failed=$((_failed + 1))
            continue
        fi

        if ! git -C "$_path" rev-parse --git-dir >/dev/null 2>&1; then
            wt_warn "  $_path 不是 git 仓库，无法确定版本，跳过"
            continue
        fi
        # 脏检查扣掉 wtool 自己生成的文件（release.json / download.md / 下载块）。
        # 不扣的话：一次发布写完文档 → 项目变脏 → 下一轮 publish
        # 以"有未提交改动"拒绝它 —— 一次发布把下一次发布堵死。
        _dirty=$(wt_git_dirty "$_path")
        if [ "${WTOOL_FORCE:-0}" != 1 ] && [ -n "$_dirty" ]; then
            wt_warn "  $_path 有未提交改动，拒绝发布（先提交，或加 --force）"
            wt_warn "  （wtool 自己生成的文件已豁免，下面是真实改动）"
            printf '%s\n' "$_dirty" | head -5 | sed 's/^/      /' >&2
            continue
        fi

        # ⚠️ `.source` 是内部标记（来源：packed / downloaded），**不上传、不进清单**。
        # 它以点开头，所以 `release/*` 这种 shell 展开本来也看不到它 ——
        # 这里显式排除是为了 find 那条路。
        _files=$(find "$_rel" -maxdepth 1 -type f ! -name '.source' | LC_ALL=C sort)
        _n=$(printf '%s\n' "$_files" | awk 'NF{n++} END{print n+0}')
        if [ "$_n" = 0 ]; then
            wt_warn "  release/ 里什么都没有，跳过（先 wtool pack-release $_pid）"
            _failed=$((_failed + 1))
            continue
        fi

        if wt_dry; then
            wt_step "[dry-run] 上传 $_n 个文件 → $_repo $_tag"
            wt_step "[dry-run] 之后写 scripts/release.json（记得提交）"
            _done=$((_done + 1))
            continue
        fi

        wt_publish_gh_release "$_repo" "$_tag" "$_pid $_date" \
            "由 wtool pack-release + publish-release 生成。内容与每卷的 sha256 见 dist.json。"
        # shellcheck disable=SC2086
        if ! wt_publish_gh_upload "$_repo" "$_tag" $_files; then
            _failed=$((_failed + 1))
            continue
        fi
        wt_publish_record "$_pid" "$_repo" "$_tag" "$_n" "release:$_tag"

        # 发布声明：**提交进仓库**的 scripts/release.json（ADR-026）。
        # 它是 download-release 唯一要读的东西，所以必须在上传成功之后才写。
        _targets=$(ls -d "$_path"/output/*/ 2>/dev/null |
                   while read -r _t; do basename -- "$_t"; done | paste -sd, -)
        # "$_dirty" 已经扣掉 wtool 自己生成的文件（release.json / download.md）
        _dirty_flag=0
        [ -n "$_dirty" ] && _dirty_flag=1
        python3 "$PY" release-json \
            --release-dir "$_rel" --dist "$_rel/dist.json" \
            --project-id "$_pid" --engine "$ENGINE_VERSION" \
            --at "$(date -Iseconds)" --dirty "$_dirty_flag" \
            --targets "$_targets" > "$_scratch/release.json" \
            || { wt_warn "  生成 release.json 失败 —— 文件传上去了，但清单没更新"; continue; }
        wt_atomic_write "$_path/scripts/release.json" "$_scratch/release.json" \
            || { wt_warn "  写不了 scripts/release.json"; continue; }
        wt_info "  已写 scripts/release.json（下载清单）—— **记得提交**："
        wt_info "    git -C $_path add scripts/release.json && git -C $_path commit -m '发布 $_tag'"

        _pubbed="${_pubbed:-} $_rel"
        _done=$((_done + 1))
    done
    exec 3<&-

    # 产物交付给 --out（如果指定了）
    if [ -n "${_outdir:-}" ] && ! wt_dry; then
        _copied=0
        for _d in ${_pubbed:-}; do
            for _f in "$_d"/*; do
                [ -f "$_f" ] || continue
                cp -f -- "$_f" "$_outdir/" && _copied=$((_copied + 1))
            done
        done
        [ "$_copied" -gt 0 ] && wt_info "产物已放到 $_outdir（$_copied 个文件）"
    fi

    # 只有这一轮真的推上去了东西，才去改文档。
    # 一个都没发出去还去刷新，等于拿"什么都没发生"去覆盖现状。
    if [ "$_done" -gt 0 ]; then
        wt_refresh_downloads
    elif ! wt_dry; then
        wt_warn "没有发布任何项目，下载链接未改动"
    fi

    # 有项目没发出去就必须**非零退出**。
    # 这条不能省：上传到一半断线时，如果退出码是 0，看日志的人（和调用它的
    # 后台任务）会以为发布成功了 —— 实测被骗过一次（见 ADR-016 的注释）。
    if [ "$_failed" -gt 0 ]; then
        wt_warn "$_failed 个项目没有发出去（见上面的原因）"
        return 1
    fi
}


# --------------------------------------------------------------------------
# 刷新"没有 git clone 时怎么装"那一节的下载链接
#
# 这件事必须脚本做：手工维护的链接一定会过期，而过期的下载链接比没有链接
# 更糟——照着做的人只会拿到 404。
#
# 哪些项目和仓由项目表决定，链接则一律以**GitHub 上真实存在的 release**
# 为准（gh release view），不是拿本地记录猜——否则文档里会出现点不开的地址。
# --------------------------------------------------------------------------
wt_refresh_downloads() {
    # 目标文档靠标记自己声明，不写死路径
    # 只认"整行就是这个标记"的文件。用 -F 匹配子串会误伤：
    # 任何一篇**提到**这个标记的文档都会被当成目标
    # （实测把 harness/BACKLOG.md 当成了下载页，然后刷失败）。
    _doc=$(grep -rl --include='*.md' -E '^<!-- >>> wtool:downloads >>> -->[[:space:]]*$' \
               "$WTOOL_ROOT" 2>/dev/null | head -1)
    if [ -z "$_doc" ]; then
        wt_info "没有文档带 wtool:downloads 标记，跳过下载链接刷新"
        return 0
    fi
    if wt_dry; then
        wt_step "[dry-run] 刷新下载链接块: ${_doc#$WTOOL_ROOT/}"
        return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
        wt_warn "没有 gh，跳过下载链接刷新（${_doc#$WTOOL_ROOT/}）"
        return 0
    fi

    _rows=$(mktemp "${TMPDIR:-/tmp}/wtool-dl.XXXXXX")
    : > "$_rows"
    while IFS='	' read -r _prio _pid _path _kind _script _tpl _to; do
        [ -n "${_pid:-}" ] || continue
        [ "$_kind" = "none" ] && continue
        if [ "$_to" != "-" ] && [ -n "$_to" ]; then
            _repo=$_to
        else
            _repo=$(wt_publish_repo_of "$_path" 2>/dev/null) || continue
        fi
        _tag=$(wt_publish_tag "$_tpl")
        # 以 GitHub 上的实际资产为准
        gh release view "$_tag" --repo "$_repo" --json assets \
            --jq '.assets[] | "\(.name)\t\(.url)\t\(.size)"' 2>/dev/null |
        while IFS='	' read -r _name _url _size; do
            [ -n "${_name:-}" ] || continue
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$_pid" "$_repo" "$_tag" "$_name" "$_url" "$_size" >> "$_rows"
        done
    done <<EOF
$(python3 "$PY" publish-list --root "$WTOOL_ROOT")
EOF

    _n=$(awk 'END { print NR }' "$_rows" 2>/dev/null || echo 0)

    # 「查到 0 个资产」不等于「没有项目可发布」。
    # gh 没登录、网络断了、release 被删，都会走到这里。
    # 这两件事必须分开：前者绝不能动文档。
    # 踩过：gh 查询失败 + 空表覆盖了 30 条真实下载链接。
    if [ "$_n" = 0 ] && [ "${WTOOL_FORCE:-0}" != 1 ] \
       && grep -qE '^\|[^|]+\|' "$_doc" 2>/dev/null; then
        wt_warn "查到 0 个资产，但 ${_doc#$WTOOL_ROOT/} 里已有下载表 —— 拒绝用空表覆盖"
        wt_warn "  可能原因：gh 未登录 / 网络不通 / release 被删"
        wt_warn "  确认确实要清空，加 --force 再来"
        rm -f -- "$_rows"
        return 0
    fi

    _new=$(mktemp "${TMPDIR:-/tmp}/wtool-doc.XXXXXX")
    if python3 "$PY" update-downloads --doc "$_doc" --rows "$_rows" > "$_new" 2>/dev/null; then
        if cmp -s "$_doc" "$_new"; then
            wt_info "下载链接块没有变化（$_n 个资产）"
        else
            cp -f -- "$_new" "$_doc"
            wt_info "已刷新下载链接块: ${_doc#$WTOOL_ROOT/}（$_n 个资产）"
        fi
    else
        wt_warn "刷新下载链接块失败: ${_doc#$WTOOL_ROOT/}"
    fi
    rm -f -- "$_rows" "$_new"
}

_publish_kind_cn() {
    case $1 in
        source) printf '源码包' ;;
        none)   printf '不发布' ;;
        *)      printf '%s' "$1" ;;
    esac
}

# --------------------------------------------------------------------------
# push-layer / pull-layer / layer-save / layer-load / unpack-layer
#
# **第二条发布通道：容器镜像仓库**。运的和 pack-release / publish-release（GitHub 分卷那条）
# 是同一份东西 —— `<项目>/layer/<target>/` 里那几个**真镜像**：
#
#   layer-save     docker 里的镜像              →  layer/<target>/（OCI 布局，ADR-024）
#   layer-load     layer/<target>/              →  docker
#   unpack-layer   layer/<target>/ 的顶层 blob  →  output/<target>/<层>/（**不联网、不要 docker**）
#   push-layer     layer/<target>/              →  镜像仓库
#   pull-layer     镜像仓库                     →  layer/<target>/（**目标机不需要 docker**）
#
# 为什么值得多这条通道（2026-09-26 实测）：上传两条路一样慢（~0.25 MB/s），
# 但下载 **ACR 10.2 MB/s vs GitHub 2.6~4.8 MB/s** —— 发布一次慢，取用快一倍多。
#
# ⚠️ **两个方向用的工具不一样，是有意的**（实测挑出来的，不是随手选的）：
#   push 用 **docker push**：`crane push` 把整个 blob 塞进一个 PATCH，ACR 传到 ~30MB
#        就 connection reset，而且重试从 offset 0 重来（hazards O1）；docker push 分块
#        5MB，一次就过 —— 代价是推的机器上要有 docker（构建机上本来就有）。
#   pull 用 **skopeo**：它往 oci: 布局里写第二个镜像时会**合并** index.json（实测：
#        两个 tag 各一条、共享的 blob 只存一份），而且**不需要 docker** ——
#        目标机上 `unpack-layer` 直接读 blob。
#
# 完整设计见 harness/architecture.md §5.1；踩过的坑见 harness/docs/hazards.md O 节。

# registry 前缀的形状：<域名>/<命名空间>，例如
#   crpi-xxxx.cn-chengdu.personal.cr.aliyuncs.com/wtool-docker-registry
# 镜像名 = <前缀>/<项目 basename>；tag = <层名（/ 换成 -）>-<target>
wt_layer_repo() { printf '%s/%s\n' "$1" "$(basename "$2")"; }
wt_layer_tag()  { printf '%s-%s\n' "$(printf '%s' "$1" | tr '/' '-')" "$2"; }

# 读一棵 layer/<target>/ 布局的层清单：一行一个镜像，TSV 五列
#   层名 <TAB> target <TAB> docker 里的镜像名 <TAB> manifest digest <TAB> ref.name
# "按层名找镜像"的操作（push / unpack）都从这里拿清单 —— 唯一入口。
#
# ‼️ 空值写成 `-`，**不能是真空白**：TAB 在 shell 里算 IFS 空白字符，
#    `IFS=<TAB> read a b c d e` 会把连续的 TAB **折成一个** —— 空字段直接消失，
#    后面的列整体左移（实测踩过：image 是空的时候，digest 被当成了镜像名）。
#    这也是引擎别处 TSV 一律用 `-` 占位的原因。
wt_layer_entries() {   # <layout 目录>
    python3 - "$1" <<'INNER_PY'
import json, os, sys
lay = sys.argv[1]
try:
    with open(os.path.join(lay, "index.json"), encoding="utf-8") as fh:
        mans = json.load(fh).get("manifests", [])
except Exception:
    sys.exit(0)
for m in mans:
    a = m.get("annotations") or {}
    print("\t".join([a.get("io.wtool.layer") or "-", a.get("io.wtool.target") or "-",
                     a.get("io.wtool.image") or "-", m.get("digest") or "-",
                     a.get("org.opencontainers.image.ref.name") or "-"]))
INNER_PY
}

# 给布局里某一个 manifest 补 annotation —— pull 回来的镜像要知道"这是哪一层"。
# 认的锚是 skopeo 写进 index.json 的 ref.name（就是我们给它的那个 tag）。
# $1=layout 目录  $2=ref.name  $3=层名  $4=target  $5=镜像名（可选）
wt_layer_annotate() {
    python3 - "$@" <<'INNER_PY'
import json, os, sys
lay, refname, layer, target = sys.argv[1:5]
image = sys.argv[5] if len(sys.argv) > 5 else ""
p = os.path.join(lay, "index.json")
with open(p, encoding="utf-8") as fh:
    idx = json.load(fh)
hit = 0
for m in idx.get("manifests", []):
    a = m.setdefault("annotations", {})
    if a.get("org.opencontainers.image.ref.name") != refname:
        continue
    a["io.wtool.layer"] = layer
    a["io.wtool.target"] = target
    if image:
        a["io.wtool.image"] = image
    hit += 1
if not hit:
    sys.exit("index.json 里没有 ref.name=%s 的条目" % refname)
tmp = p + ".new"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(idx, fh, ensure_ascii=False, indent=2)
os.replace(tmp, p)
INNER_PY
}

wt_need_skopeo() {
    _ws=${WTOOL_SKOPEO:-skopeo}
    command -v "$_ws" >/dev/null 2>&1 || wt_die "找不到 skopeo（拉层用的）。

  · 装一个：sudo apt install skopeo
  · 或者指路径：WTOOL_SKOPEO=<路径> wtool pull-layer …
  · 不拉也行：包是从 GitHub 下来的就 wtool unpack-release，用不着它"
    printf '%s\n' "$_ws"
}

# --------------------------------------------------------------------------
# layer/ 存储：docker 镜像 ⇄ <项目>/layer/<target>/（OCI 镜像布局）
#
# 决策和实测数据见 harness/docs/adr/0024。**两条管道就是全部**：
#   写：docker save <镜像> | tar -x -C layer/<target>/     ← tar 只当管道，不落盘
#   读：tar -c -C layer/<target>/ . | docker load
# 磁盘上留下的是**目录**：blobs/sha256/… 按内容命名，所以父链天然只存一份
# （实测两份 tar 324M+424M 合进同一目录只有 424M）；装回去是同一个 image ID。
#
# ⚠️ `layer/` 只对 kind="docker" 的项目存在（本地直接编的项目没有层）。
# --------------------------------------------------------------------------

wt_layer_dir() { printf '%s/layer/%s\n' "$1" "$2"; }   # <项目目录> <target>

# 把一个 docker 镜像写进 layer/<target>/。同一棵 layout 里的 index.json 要**合并**
# —— 直接把后一个 save 的 index.json 覆盖上去，前一个镜像的条目就没了（实测过）。
wt_layer_import() {   # <项目目录> <target> <镜像> <层名>
    _li_dir=$(wt_layer_dir "$1" "$2")
    _li_img=$3; _li_name=$4
    command -v docker >/dev/null 2>&1 || wt_die "layer-save 需要 docker（它要把镜像从 docker 里导出来）"
    docker image inspect "$_li_img" >/dev/null 2>&1 || wt_die "docker 里没有这个镜像: $_li_img"
    _li_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wtool-lsave.XXXXXX") || return 1
    if ! docker save "$_li_img" | tar -x -C "$_li_tmp"; then
        rm -rf -- "$_li_tmp"; return 1
    fi
    wt_run mkdir -p -- "$_li_dir/blobs/sha256"
    if [ ! -f "$_li_dir/oci-layout" ]; then
        printf '{"imageLayoutVersion":"1.0.0"}\n' > "$_li_dir/.oci-layout.new"
        mv -f -- "$_li_dir/.oci-layout.new" "$_li_dir/oci-layout"
    fi
    # blob 同名就是同内容（名字就是它的 sha256）→ 已有的不覆盖，父链只留一份
    cp -an -- "$_li_tmp/blobs/sha256/." "$_li_dir/blobs/sha256/" 2>/dev/null || \
        cp -a -- "$_li_tmp/blobs/sha256/." "$_li_dir/blobs/sha256/" || {
            rm -rf -- "$_li_tmp"; wt_die "blob 拷不进 $_li_dir/blobs/sha256"; }
    python3 - "$_li_dir/index.json" "$_li_tmp/index.json" "$_li_name" "$2" "$_li_img" \
        > "$_li_dir/index.json.new" <<'PY' || { rm -rf -- "$_li_tmp"; return 1; }
import json, sys
cur_p, new_p, layer, target = sys.argv[1:5]
image = sys.argv[5] if len(sys.argv) > 5 else ""
def load(p):
    try:
        with open(p, encoding="utf-8") as fh:
            return json.load(fh).get("manifests", [])
    except Exception:
        return []
entries = load(cur_p)
have = {e.get("digest") for e in entries}
for e in load(new_p):
    if e.get("digest") in have:
        continue
    ann = e.setdefault("annotations", {})
    ann["io.wtool.layer"] = layer
    ann["io.wtool.target"] = target
    if image:
        # docker 里的镜像名（save 的时候是什么就记什么）—— push-layer 靠它 docker tag
        ann["io.wtool.image"] = image
    entries.append(e)
print(json.dumps({"schemaVersion": 2,
                  "mediaType": "application/vnd.oci.image.index.v1+json",
                  "manifests": entries}, ensure_ascii=False, indent=2))
PY
    mv -f -- "$_li_dir/index.json.new" "$_li_dir/index.json"
    rm -rf -- "$_li_tmp"
    wt_info "  已存进 layer/$2/（层名 $_li_name）"
}

# 把 layer/<target>/ 里的镜像装回 docker（接着构建 / 恢复容器用）。
wt_layer_load() {   # <项目目录> <target>
    _ll_dir=$(wt_layer_dir "$1" "$2")
    [ -f "$_ll_dir/index.json" ] || wt_die "没有 $_ll_dir —— 先 wtool layer-save（或 pull-layer）"
    command -v docker >/dev/null 2>&1 || wt_die "layer-load 需要 docker"
    wt_run tar -c -C "$_ll_dir" . | docker load
}

cmd_layer_save() {
    _targets=""; _img=""; _t=""; _name=""
    for arg in "$@"; do
        case $arg in
            --dry-run) WTOOL_DRY_RUN=1 ;;
            --image=*) _img=${arg#--image=} ;;
            --target=*) _t=${arg#--target=} ;;
            --layer=*)  _name=${arg#--layer=} ;;
            -*)        wt_die "未知参数: $arg" ;;
            *)         _targets="$_targets $arg" ;;
        esac
    done
    [ -n "$_targets" ] && [ -n "$_img" ] || wt_die "用法: wtool layer-save <项目> --image=<镜像> [--target=<os_ver>] [--layer=<层名>]

  把 docker 里的一个镜像**存进项目的 layer/<target>/**（OCI 镜像布局，blob 按 sha256 去重）。
  层名不给就从镜像 tag 推；target 不给就从 output/ 推一个。

  磁盘上留下的是**目录**不是 tar：blobs/sha256/… 按内容命名，父子层共用一份。"
    # 层名不给就从镜像名推：去掉 registry 路径，**也去掉 tag / digest** ——
    # 层名最后要当 docker tag 用，冒号在里面非法（实测：`--image=astro/nvim_base:ubuntu_22.04`
    # 会推出层名 `nvim_base:ubuntu_22.04`，push 时拼成 `…:nvim_base:ubuntu_22.04-ubuntu_22.04`，
    # docker 直接 "invalid reference format"）。
    [ -n "$_name" ] || _name=$(printf '%s' "${_img##*/}" | sed 's/[:@].*$//')
    for _want in $_targets; do
        _row=$(wt_resolve_project "$_want") || exit $?
        _pid=$(printf '%s\n' "$_row" | cut -f2); _path=$(printf '%s\n' "$_row" | cut -f3)
        [ -n "$_t" ] || _t=$(wt_guess_target "$_path")
        [ -n "$_t" ] || wt_die "$_pid 没有 output/ 目标 —— 用 --target=<os_ver> 明确指一个"
        wt_info "── $_pid  $_img → layer/$_t/"
        if wt_dry; then wt_step "[dry-run] docker save $_img | tar -x -C $(wt_layer_dir "$_path" "$_t")"; continue; fi
        wt_layer_import "$_path" "$_t" "$_img" "$_name" || wt_die "存不进 layer/$_t"
    done
}

cmd_layer_load() {
    _targets=""; _t=""
    for arg in "$@"; do
        case $arg in
            --dry-run) WTOOL_DRY_RUN=1 ;;
            --target=*) _t=${arg#--target=} ;;
            -*)        wt_die "未知参数: $arg" ;;
            *)         _targets="$_targets $arg" ;;
        esac
    done
    [ -n "$_targets" ] || wt_die "用法: wtool layer-load <项目> [--target=<os_ver>]

  把 <项目>/layer/<target>/ 里的镜像**装回 docker**（tar 只当管道）。
  要接着构建、或者恢复一个已经没了的容器，就用它。"
    for _want in $_targets; do
        _row=$(wt_resolve_project "$_want") || exit $?
        _pid=$(printf '%s\n' "$_row" | cut -f2); _path=$(printf '%s\n' "$_row" | cut -f3)
        [ -n "$_t" ] || _t=$(wt_guess_target "$_path")
        [ -n "$_t" ] || wt_die "$_pid 没有 output/ 目标 —— 用 --target=<os_ver> 明确指一个"
        wt_info "── $_pid  layer/$_t/ → docker"
        wt_layer_load "$_path" "$_t" || wt_die "装不回 docker"
    done
}

# 从 layer/<target>/ 里找出某一层的**顶层 blob**（就是"这一层"，ADR-024 §8 那条链：
# index.json → manifest → layers[-1] → blobs/sha256/<digest>）。
# 层名不给（或给 -）时：layout 里只有一个镜像就用它，多个就要求明确指一个。
wt_layer_last_blob() {   # <layout 目录> [层名]
    _lb_dir=$1; _lb_want=${2:-}
    [ -f "$_lb_dir/index.json" ] || return 1
    python3 - "$_lb_dir" "$_lb_want" <<'INNER_PY'
import json, os, sys
lay, want = sys.argv[1], sys.argv[2]
idx = json.load(open(os.path.join(lay, "index.json"), encoding="utf-8"))
mans = idx.get("manifests", [])
if want:
    mans = [m for m in mans
            if (m.get("annotations") or {}).get("io.wtool.layer") == want]
if not mans:
    sys.exit("找不到层%s（layout 里有 %d 个镜像）"
             % (" " + want if want else "", len(idx.get("manifests", []))))
if len(mans) > 1:
    sys.exit("layout 里有多个层（%s）—— 用 --layer= 明确指一个"
             % ", ".join(sorted((m.get("annotations") or {}).get("io.wtool.layer", "?")
                                for m in mans)))
md = mans[0]["digest"].split(":", 1)[-1]
mf = json.load(open(os.path.join(lay, "blobs", "sha256", md), encoding="utf-8"))
print(os.path.join(lay, "blobs", "sha256", mf["layers"][-1]["digest"].split(":", 1)[-1]))
print((mans[0].get("annotations") or {}).get("io.wtool.layer", ""))
INNER_PY
}

# 扫一棵 payload 目录，生成 OWNED.tsv（三列：相对影子 $HOME 的路径 	 值 	 层名）。
# 值的三态（install.sh 的 verify_layer 认这个约定）：
#   64 位 sha256 / `-`（读不到）/ `L:<readlink 原值>`
# ⚠️ 软链必须**自己判**，不能丢给 sha256sum —— 它会**跟随**软链，
#    把"目标的内容"记成"这个文件的内容"（2026-09-26 实测踩过：
#    发布出去的包在干净机器上因此根本装不上）。
# ⚠️ 指向 payload **外面**的软链换台机器必然是断的 —— 这一层不能用，直接失败。
wt_owned_scan() {   # <payload 目录> <层名> <OWNED.tsv 路径>
    _os_pay=$1; _os_name=$2; _os_out=$3
    _os_esc="$_os_pay/.escaping-links.$$"
    : > "$_os_esc"
    ( cd -- "$_os_pay" && find . -type f -o -type l | sed 's|^\./||' | LC_ALL=C sort ) \
    | while IFS= read -r _os_f; do
        _os_p="$_os_pay/$_os_f"
        if [ -L "$_os_p" ]; then
            _os_t=$(readlink -- "$_os_p")
            case $_os_t in
                /*) _os_out2=1 ;;
                *)  _os_real=$(cd -- "$(dirname -- "$_os_p")" && pwd)/$_os_t
                    case $_os_real in
                        "$_os_pay"/*) _os_out2=0 ;;
                        *)            _os_out2=1 ;;
                    esac ;;
            esac
            [ "$_os_out2" = 1 ] && printf '%s -> %s\n' "$_os_f" "$_os_t" >> "$_os_esc"
            printf '%s\tL:%s\t%s\n' "$_os_f" "$_os_t" "$_os_name"
        else
            _os_h=$(sha256sum -- "$_os_p" 2>/dev/null | cut -d' ' -f1)
            printf '%s\t%s\t%s\n' "$_os_f" "${_os_h:--}" "$_os_name"
        fi
    done > "$_os_out" 2>/dev/null || true
    if [ -s "$_os_esc" ]; then
        {
            echo "错误: $_os_name 这一层里有指向包**外面**的软链 —— 换台机器必然悬空:"
            sed 's/^/    /' -- "$_os_esc"
            echo "  指向系统包（apt 装出来的）的，要么把真身拷进 \$PREFIX，要么别建这条链。"
        } >&2
        rm -f -- "$_os_esc"
        return 1
    fi
    rm -f -- "$_os_esc"
    return 0
}

# 缺 --target= 时从 output/ 里推一个出来（只有一个才敢推）
wt_guess_target() {   # $1=项目目录
    # ‼️ 必须永远 return 0：调用点普遍写成 `[ -n "$_t" ] || _t=$(wt_guess_target …)`，
    # 而 `set -e` 会看整条 `||` 列表的状态 —— 猜不到时返回 1 会让 wtool **一声不吭地退出 1**
    # （2026-09-28 实测：unpack-layer 在 output/ 还没建时就死得无声无息）。
    _gt=$(ls -d "$1"/output/*/ 2>/dev/null | head -1) || true
    [ -n "$_gt" ] && basename -- "$_gt"
    return 0
}

cmd_pull_layer() {
    _targets=""; _reg=""; _only_t=""; _only_l=""
    for arg in "$@"; do
        case $arg in
            --dry-run)    WTOOL_DRY_RUN=1 ;;
            --registry=*) _reg=${arg#--registry=} ;;
            --target=*)   _only_t=${arg#--target=} ;;
            --layer=*)    _only_l=${arg#--layer=} ;;
            -*)           wt_die "未知参数: $arg" ;;
            *)            _targets="$_targets $arg" ;;
        esac
    done
    [ -n "$_targets" ] || wt_die "用法: wtool pull-layer <项目>... [--registry=<前缀>] [--target=<os_ver>] [--layer=<层名>]

  从镜像仓库把**层镜像**拉进 <项目>/layer/<target>/（OCI 布局，ADR-024）。接着：
    wtool unpack-layer <项目>     # layer/ → output/（不需要 docker）
    wtool install      <项目>

  <前缀> 形如 crpi-xxxx.cn-chengdu.personal.cr.aliyuncs.com/wtool-docker-registry，
  默认取 \$WTOOL_LAYER_REGISTRY。**目标机上不需要 docker**（只要一个 skopeo）。"
    [ -n "$_reg" ] || _reg=${WTOOL_LAYER_REGISTRY:-}
    [ -n "$_reg" ] || wt_die "没给 registry：--registry=<前缀> 或 export WTOOL_LAYER_REGISTRY=<前缀>"
    _sk=$(wt_need_skopeo) || exit $?

    _done=0
    for _want in $_targets; do
        _row=$(wt_resolve_project "$_want") || exit $?
        _pid=$(printf '%s\n' "$_row" | cut -f2)
        _path=$(printf '%s\n' "$_row" | cut -f3)
        _repo=$(wt_layer_repo "$_reg" "$_path")
        [ -n "$_only_t" ] || _only_t=$(wt_guess_target "$_path")
        if [ -z "$_only_t" ]; then
            _lt=$(ls -d "$_path"/layer/*/ 2>/dev/null | head -1) || true
            [ -n "$_lt" ] && _only_t=$(basename -- "$_lt")
        fi
        [ -n "$_only_t" ] || wt_die "$_pid 没有 output/ 也没有 layer/ 目标 —— 用 --target=<os_ver> 指一个"
        _lay=$(wt_layer_dir "$_path" "$_only_t")
        wt_info "── $_pid  ← $_repo:*-$_only_t"

        # tag 清单以**仓库**为准 —— 这样在一台连 output/ 都还空着的机器上也能拉
        # （这正是"装到公司机器"那个场景：那边没有本地构建产物）。
        _tags=$("$_sk" list-tags "docker://$_repo" 2>/dev/null | python3 -c '
import json, sys
try:
    print("\n".join(json.load(sys.stdin).get("Tags") or []))
except Exception:
    pass') || true
        [ -n "$_tags" ] || wt_die "读不到 $_repo 的 tag 列表（仓库不存在？没登录？skopeo login <域名>）

  凭据：skopeo login --username <账号> <域名>   （阿里云 ACR 的密码在控制台设）"

        _n=0
        for _tag in $_tags; do
            case $_tag in
                *-"$_only_t") _layer=${_tag%-"$_only_t"} ;;
                *) continue ;;
            esac
            # tag 里的 - 是层名里的 / 换来的（tag 只认 [A-Za-z0-9_.-]）。
            # 还原两步：
            #   ① 本地这棵 layout 里已经有这个 tag（重拉/续拉）→ 用它记着的层名（最准）
            #   ② 没有（全新机器）→ 按 - → / 还原
            # 局限：层名里如果有同时存在 `a-b` 和 `a/b` 两个层，这一步会有歧义。
            # 本项目的层名是 main / nvim_base / astronvim_base / lang/<语言>，不冲突。
            _cand=$(wt_layer_entries "$_lay" | awk -F'\t' -v t="$_tag" '$1!="-" && $5==t{print $1; exit}')
            if [ -n "$_cand" ]; then
                _layer=$_cand
            else
                _layer=$(printf '%s' "$_layer" | tr '-' '/')
            fi
            [ -z "$_only_l" ] || [ "$_layer" = "$_only_l" ] || continue

            _n=$((_n + 1))
            if wt_dry; then
                wt_step "[dry-run] $_repo:$_tag → layer/$_only_t/$_layer"
                continue
            fi
            wt_run mkdir -p -- "$_lay"
            [ -f "$_lay/oci-layout" ] || printf '{"imageLayoutVersion":"1.0.0"}\n' > "$_lay/oci-layout"
            # ⚠️ 不能用 wt_run：它一失败就 wt_die（整条命令退出），而这里要的是
            #    "这个 tag 拉不动就跳过、接着拉下一个"。
            if ! "$_sk" copy --all "docker://$_repo:$_tag" "oci:$_lay:$_tag"; then
                wt_warn "拉 $_tag 失败，跳过"
                continue
            fi
            wt_layer_annotate "$_lay" "$_tag" "$_layer" "$_only_t" "docker://$_repo:$_tag" || \
                wt_die "拉回来的 $_tag 认不出来（annotation 写不进 $_lay/index.json）"
            wt_step "$_layer（blob 只存一份；整个 layout $(du -sh "$_lay" 2>/dev/null | cut -f1)）"
        done
        [ "$_n" -gt 0 ] || wt_warn "一个层都没拉到（target=$_only_t，仓库里没匹配的 tag？）"
        _done=$((_done + 1))
    done
    wt_info "pull-layer 完成（$_done 个项目）—— 接着 wtool unpack-layer <项目>"
}

cmd_push_layer() {
    _targets=""; _reg=""; _only_t=""; _only_l=""
    for arg in "$@"; do
        case $arg in
            --dry-run)    WTOOL_DRY_RUN=1 ;;
            --registry=*) _reg=${arg#--registry=} ;;
            --target=*)   _only_t=${arg#--target=} ;;
            --layer=*)    _only_l=${arg#--layer=} ;;
            -*)           wt_die "未知参数: $arg" ;;
            *)            _targets="$_targets $arg" ;;
        esac
    done
    [ -n "$_targets" ] || wt_die "用法: wtool push-layer <项目>... [--registry=<前缀>] [--target=<os_ver>] [--layer=<层名>]

  把 <项目>/layer/<target>/ 里的层镜像推到镜像仓库：tag = <层名（/ 换成 -）>-<target>。
  推的是**真镜像**（基础层 + 每层一个 commit），blob 按 sha256 去重 ——
  共享父链只在第一个镜像里传一次。

  ⚠️ 要 docker：`crane push` 推大 blob 会 connection reset（hazards O1），
     docker push 分块 5MB 才过得去。构建机上本来就有 docker（ADR-024 §8）。"
    [ -n "$_reg" ] || _reg=${WTOOL_LAYER_REGISTRY:-}
    [ -n "$_reg" ] || wt_die "没给 registry：--registry=<前缀> 或 export WTOOL_LAYER_REGISTRY=<前缀>"
    command -v docker >/dev/null 2>&1 || wt_die "push-layer 要 docker（crane push 推不了大 blob，见 hazards O1）"

    _scratch=$(mktemp -d "${TMPDIR:-/tmp}/wtool-push.XXXXXX")
    trap 'rm -rf -- "$_scratch"' EXIT INT TERM

    _done=0
    for _want in $_targets; do
        _row=$(wt_resolve_project "$_want") || exit $?
        _pid=$(printf '%s\n' "$_row" | cut -f2)
        _path=$(printf '%s\n' "$_row" | cut -f3)
        _repo=$(wt_layer_repo "$_reg" "$_path")
        [ -n "$_only_t" ] || _only_t=$(wt_guess_target "$_path")
        if [ -z "$_only_t" ]; then
            _lt=$(ls -d "$_path"/layer/*/ 2>/dev/null | head -1) || true
            [ -n "$_lt" ] && _only_t=$(basename -- "$_lt")
        fi
        [ -n "$_only_t" ] || wt_die "$_pid 没有 output/ 也没有 layer/ 目标 —— 用 --target=<os_ver> 指一个"
        _lay=$(wt_layer_dir "$_path" "$_only_t")
        [ -f "$_lay/index.json" ] || wt_die "没有 $_lay —— 先 wtool layer-save / pull-layer"

        wt_layer_entries "$_lay" | awk -F'\t' -v t="$_only_t" '$1!="-" && ($2=="-" || $2==t)' \
            > "$_scratch/rows"
        [ -s "$_scratch/rows" ] || wt_die "$_lay 里一个层镜像都没有（index.json 是空的？）"
        wt_info "── $_pid  layer/$_only_t/ → $_repo"

        if wt_dry; then
            while IFS="$(printf '\t')" read -r _l _lt2 _limg _ldg _lrn; do
                [ -z "$_only_l" ] || [ "$_l" = "$_only_l" ] || continue
                wt_step "[dry-run] $_l → $_repo:$(wt_layer_tag "$_l" "$_only_t")"
            done < "$_scratch/rows"
            continue
        fi

        # 布局 → docker（tar 只当管道；镜像名字由 index.json 里 docker 自己写的
        # io.containerd.image.name 还原），再从 docker 推上去。
        wt_run tar -c -C "$_lay" . | docker load > "$_scratch/load.log" 2>&1 || {
            tail -5 -- "$_scratch/load.log" >&2
            wt_die "布局装不回 docker（$_lay）"
        }
        _n=0
        while IFS="$(printf '\t')" read -r _l _lt2 _limg _ldg _lrn; do
            [ "$_l" != "-" ] || continue
            [ -z "$_only_l" ] || [ "$_l" = "$_only_l" ] || continue
            [ "$_limg" != "-" ] || wt_die "层 $_l 不知道对应 docker 里的哪个镜像（layout 是旧版写的）。
  重新存一次：wtool layer-save <项目> --image=<镜像> --layer=$_l"
            _tag=$(wt_layer_tag "$_l" "$_only_t")
            wt_run docker tag "$_limg" "$_repo:$_tag" || wt_die "docker tag $_limg → $_repo:$_tag 失败"
            if ! docker push "$_repo:$_tag" > "$_scratch/push.log" 2>&1; then
                tail -5 -- "$_scratch/push.log" >&2
                wt_die "推 $_tag 失败 —— dockerd 的代理配好了吗？（hazards O2）"
            fi
            wt_step "$_l → $_repo:$_tag"
            _n=$((_n + 1))
        done < "$_scratch/rows"
        [ "$_n" -gt 0 ] || wt_warn "一个层都没推（--layer=$_only_l 在这棵 layout 里没有？）"
        _done=$((_done + 1))
    done
    wt_info "push-layer 完成（$_done 个项目）"
}

cmd_unpack_layer() {
    _targets=""; _t=""; _layer=""; _outdir=""
    for arg in "$@"; do
        case $arg in
            --dry-run)  WTOOL_DRY_RUN=1 ;;
            --layer=*)  _layer=${arg#--layer=} ;;
            --target=*) _t=${arg#--target=} ;;
            --output=*) _outdir=${arg#--output=} ;;
            -*)         wt_die "未知参数: $arg" ;;
            *)          _targets="$_targets $arg" ;;
        esac
    done
    [ -n "$_targets" ] || wt_die "用法: wtool unpack-layer <项目> [--layer=<层名>] [--target=<os_ver>] [--output=<目录>]

  把 <项目>/layer/<target>/ 里某一层的**顶层 blob** 解成安装产物：
    → <项目>/output/<target>/<层>/{payload,OWNED.tsv}（--output= 可以指到别处）
  **不需要 docker**（直接读 blob），也不联网。

  这就是 ADR-025 那条分界：layer/ 里的镜像是**完整运行时**（一个字节都不丢），
  output/ 才是**过滤过的安装产物** —— 白障（.wh.）在这里丢掉。
  层名不给时：layout 里只有一个镜像就用它。"
    for _want in $_targets; do
        _row=$(wt_resolve_project "$_want") || exit $?
        _pid=$(printf '%s\n' "$_row" | cut -f2); _path=$(printf '%s\n' "$_row" | cut -f3)
        [ -n "$_t" ] || _t=$(wt_guess_target "$_path")
        # output/ 可能还没建（unpack-layer 正是来建它的）—— 那就看 layer/ 里现成的 target 目录
        if [ -z "$_t" ]; then
            _lt=$(ls -d "$_path"/layer/*/ 2>/dev/null | head -1) || true
            [ -n "$_lt" ] && _t=$(basename -- "$_lt")
        fi
        [ -n "$_t" ] || wt_die "$_pid 没有 output 目标，用 --target= 指定"
        _lay=$(wt_layer_dir "$_path" "$_t")
        [ -f "$_lay/index.json" ] || wt_die "没有 $_lay —— 先 wtool layer-save（或 pull-layer）"

        _blobinfo=$(wt_layer_last_blob "$_lay" "$_layer") || wt_die "$(wt_layer_last_blob "$_lay" "$_layer" 2>&1 >/dev/null)"
        _blob=$(printf '%s\n' "$_blobinfo" | sed -n 1p)
        _name=$(printf '%s\n' "$_blobinfo" | sed -n 2p)
        [ -n "$_name" ] || _name=$(basename -- "$_blob")
        _dst=${_outdir:-"$_path/output/$_t"}/$_name
        wt_info "── $_pid  layer/$_t/$_name → ${_dst#$WTOOL_ROOT/}"

        if wt_dry; then
            wt_step "[dry-run] 读 $(basename -- "$_blob") → payload/ + OWNED.tsv"
            continue
        fi
        [ -f "$_blob" ] || wt_die "blob 不在: $_blob"
        wt_run rm -rf -- "$_dst"
        wt_run mkdir -p -- "$_dst/payload"
        # 层里的形状是容器内绝对路径（root/.wtool/…），payload 要的是**相对影子 $HOME**
        # 的形状 —— 剥掉前两节。剥不干净就是"装上去路径全错"（症状：装完了敲命令找不到）。
        chmod +x "$_dst/payload" 2>/dev/null || true
        tar -xf "$_blob" -C "$_dst/payload" --strip-components=2 \
            --wildcards 'root/.wtool/*' --exclude='*/.wh.*' 2>/dev/null || true
        chmod -R a+rX "$_dst/payload" 2>/dev/null || true
        wt_owned_scan "$_dst/payload" "$_name" "$_dst/OWNED.tsv" \
            || wt_die "$_name 这一层不能用（上面列了原因）"
        wt_step "解完：$(du -sh -- "$_dst" 2>/dev/null | cut -f1)（$(awk 'END{print NR}' "$_dst/OWNED.tsv") 个文件）"
    done
}

# --------------------------------------------------------------------------
# 分发
# --------------------------------------------------------------------------
_cmd=${1:-}
[ $# -gt 0 ] && shift

case $_cmd in
    build)     cmd_build "$@" ;;
    download-release) cmd_download_release "$@" ;;
    install)   cmd_install "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    sudo-install)   cmd_sudo_install "$@" ;;
    sudo-uninstall) cmd_sudo_uninstall "$@" ;;
    sudo-bootstrap) cmd_sudo_bootstrap "$@" ;;
    download) wt_die "download 已改名 download-release，而且**语义变了**：它现在只把包下到 release/，不解包。
  接着敲：wtool unpack-release <项目>      # 解到 output/，再 wtool install
  （理由见 harness/docs/adr/0023）" ;;
    publish)  wt_die "publish 已拆成两条（各干一件事）：
  wtool pack-release    <项目>    # output/ → release/（本地打包）
  wtool publish-release <项目>    # release/ → GitHub（只上传）
  （理由见 harness/docs/adr/0023）" ;;
    provision) wt_die "provision 已改名为 sudo-install，请用：
  wtool sudo-install <项目>      # 一个
  wtool sudo-bootstrap           # 全部项目的系统层
（改名理由：要 sudo 的都叫 sudo-*，不叫 sudo-* 的永不要 sudo —— 见架构书 §0）" ;;
    pack-release)   cmd_pack_release "$@" ;;
    unpack-release) cmd_unpack_release "$@" ;;
    publish-release) cmd_publish_release "$@" ;;
    push-layer)    cmd_push_layer "$@" ;;
    pull-layer)    cmd_pull_layer "$@" ;;
    push-layers)   wt_die "push-layers 已改名 push-layer，而且**对象变了**：推的现在是 layer/<target>/ 里的**真镜像**（ADR-024），不是 output/ 打的假镜像。
  敲：wtool push-layer <项目> [--registry=<前缀>]" ;;
    pull-layers)   wt_die "pull-layers 已改名 pull-layer，而且**落点变了**：现在拉进 layer/<target>/（不再直接落 output/）。
  wtool pull-layer   <项目> [--registry=<前缀>]   # 镜像仓库 → layer/
  wtool unpack-layer <项目>                      # layer/ → output/（不需要 docker）" ;;
    pack-layer)    wt_die "pack-layer 已删除（ADR-024）：方向本来就是反的 —— 层是源，output 是层的导出物。
  现在两件事各有命令：
    wtool layer-save <项目> --image=<镜像>   # docker 镜像 → layer/<target>/
    wtool unpack-layer <项目>                # layer/<target>/ → output/" ;;
    layer-save)    cmd_layer_save "$@" ;;
    layer-load)    cmd_layer_load "$@" ;;
    unpack-layer)  cmd_unpack_layer "$@" ;;
    bootstrap) cmd_bootstrap "$@" ;;
    check)     cmd_check "$@" ;;
    repair)    cmd_repair "$@" ;;
    kill-self-forever) cmd_kill_self_forever "$@" ;;
    status)    cmd_status "$@" ;;
    doctor)    cmd_doctor "$@" ;;
    docs)      shift; [ "${1:-}" = "refresh" ] && shift
               wt_refresh_downloads ;;
    refresh-downloads) wt_refresh_downloads ;;
    init)      cmd_init "$@" ;;
    scaffold)  wt_die "scaffold 已删除（不是改名，是删掉）。新建项目用: wtool init <目录>" ;;
    validate)  python3 "$PY" validate "$@" --home "$WTOOL_HOME" --state "$WTOOL_STATE" ;;
    version)   echo "wtool engine $ENGINE_VERSION" ;;
    table)     wt_die "table 已经删掉：裸跑 wtool 就是项目表
  wtool            # 一行一个项目、一列一个能力
  wtool doctor     # 环境诊断（表也在里面）" ;;
    list)      wt_die "list 已经删掉：并进了 wtool status
  wtool status     # 登记表 + 软链检查" ;;
    env)       wt_die "env 已经删掉：并进了 wtool doctor
  wtool doctor     # 环境诊断 + 环境变量
  eval \"\$(wtool doctor --quiet)\"   # 只要 export 行" ;;
    -h|--help|help)
        # 打印文件头的注释块，不写死行号（否则加一行用法就错位）
        awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$self"
        ;;
    "")
        # 不带参数 = 看板：哪些项目装过、sudo 装过、发布过
        cmd_table --verbose --summary
        ;;
    *) wt_die "未知命令: $_cmd（用 --help 查看用法）" ;;
esac
