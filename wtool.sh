#!/bin/sh
# wtool —— wtool 集合的引擎（唯一一份，住在 wtool-bootstrap 里）
#
#   wtool.sh build     [<项目>...|all] [--dry-run]  跑项目自己的 scripts/build.sh
#   wtool.sh download  [<项目>...|all] [--dry-run]  跑 scripts/download.sh
#                      用发布页上现成的包代替自己编；产物落在和 build 相同的位置
#   wtool.sh install   <项目目录> [--dry-run] [--force] [--no-script]
#                      wtool.xml 的 link/rc 铺完之后，再跑项目自己的 install.sh
#   wtool.sh uninstall <项目目录> [--dry-run] [--force]
#   wtool.sh uninstall --id <项目id> [--dry-run] [--force]
#   wtool.sh provision <项目目录> [--dry-run] [--force] [--with-system]
#   wtool.sh publish   [<项目>...] [--tag=TAG] [--dry-run] [--force]
#                      源码包发布到项目自己的 release；kind="script" 的项目
#                      走项目内 publish.sh。不带参数则发布所有声明过的项目。
#   wtool.sh bootstrap [--with-system|--no-system|--install-only|--dry-run|--force]
#   wtool.sh status    [<项目目录>]
#   wtool.sh table     [--verbose] [--summary]
#                      一行一个项目、一列一个能力；不带参数跑 wtool 也是这个
#   wtool.sh list
#   wtool.sh validate  <项目目录>
#   wtool.sh doctor
#   wtool.sh env       [--quiet|--json]   输出可用的环境变量（带中文说明）
#   wtool.sh init      <目录> [--id ID] [--priority N] [--all]
#                      新建一个 wtool 项目（生成 wtool.xml + 可选脚本模板）
#   wtool.sh version
#
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
# 必须 export：planner 和项目的 publish.sh 都要读它。
# 不导出的话 Python 侧读不到，会退化用 basename 当项目 id。
WTOOL_ROOT=${WTOOL_ROOT:-$(dirname -- "$here")}
export WTOOL_ROOT
WTOOL_REGISTRY="$WTOOL_STATE/registry.tsv"
WTOOL_SRC=${WTOOL_SRC:-$WTOOL_HOME/.wtool/src}
WTOOL_PREFIX=${WTOOL_PREFIX:-$WTOOL_HOME/.wtool/usr}
WTOOL_FORCE=0
WTOOL_DRY_RUN=0
WTOOL_WITH_SYSTEM=0

. "$here/lib/wtool_fs.sh"
. "$here/lib/wtool_os.sh"
wt_os_detect        # 引擎自己探测，不依赖交互 shell 的环境

PY="$here/lib/wtool_plan.py"
[ -f "$PY" ] || wt_die "缺少规划器: $PY"

# 前置依赖硬检查：缺了就给一条能直接复制的命令
# （最小化系统/docker 镜像里 python3 和 git 都可能没有，见 docs/spec.md §12）
_wt_missing=""
command -v python3 >/dev/null 2>&1 || _wt_missing="$_wt_missing python3"
command -v git >/dev/null 2>&1 || _wt_missing="$_wt_missing git"
if [ -n "$_wt_missing" ]; then
    wt_die "缺少依赖:$_wt_missing
请先执行（用系统自带源，不需要证书）：
  sudo apt-get update && sudo apt-get install -y --no-install-recommends ca-certificates git python3"
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
wt_all_projects() {   # <过滤条件>：build | download | install | publish | 空=全部
    _ap_filter=$1
    python3 "$PY" publish-list --root "$WTOOL_ROOT" |
    while IFS='	' read -r _prio _pid _path _kind _script _tpl _to; do
        [ -n "${_pid:-}" ] || continue
        case $_ap_filter in
            build)    wt_project_script "$_path" build.sh    >/dev/null 2>&1 || continue ;;
            download) wt_project_script "$_path" download.sh >/dev/null 2>&1 || continue ;;
            publish)  [ "$_kind" = "none" ] && continue ;;
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
# 项目自己的脚本：build.sh / install.sh / publish.sh
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
#     editor/astronvim_v5/scripts/download.sh
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
        # （清单走 fd 3，就是为了防这个——见 cmd_publish 的注释）
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
    wt_warn "      wtool download $_ce_pid"
    wt_warn "      wtool install  $_ce_pid"
    wt_warn ""
    wt_warn "  确认要在这台机器上编，就加 --force。"
    return 1
}

# 并行度按内存封顶。
# 32 核配 16G 内存的机器很常见，WTOOL_JOBS=nproc 会让 nvim 的构建 OOM ——
# 核心数只决定快慢，内存不够是直接失败。
wt_effective_jobs() {
    _ej_cores=${WTOOL_JOBS:-$(nproc 2>/dev/null || echo 4)}
    _ej_mem=$(awk '/^MemTotal:/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)
    [ "$_ej_mem" -gt 0 ] || { printf '%s\n' "$_ej_cores"; return 0; }
    _ej_cap=$(( _ej_mem / 2 ))
    [ "$_ej_cap" -lt 1 ] && _ej_cap=1
    [ "$_ej_cores" -gt "$_ej_cap" ] && _ej_cores=$_ej_cap
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
# download：用发布页上现成的包代替"自己编"
#
# 和 build 是一对：两者都要把产物放到**同样的路径**上，
# 之后的 install 完全不关心产物是编出来的还是下下来的。
# 所以任何一个项目同时提供 scripts/build.sh 和 scripts/download.sh 时，
# 这两条路必须等价（见 guide.md「产物契约」）。
#
# 具体怎么下载、从哪拿、按什么选包，是项目脚本自己的事 ——
# 引擎只负责：找到脚本、喂好环境（含 WTOOL_ARTIFACTS）、记一笔"做过了"。
# --------------------------------------------------------------------------
cmd_download() {
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
        wt_info "这些项目提供了 scripts/download.sh："
        _n=0
        while IFS='	' read -r _prio _pid _path _kind _script _tpl _to; do
            [ -n "${_pid:-}" ] || continue
            if wt_project_script "$_path" download.sh >/dev/null 2>&1; then
                wt_step "$_pid"
                _n=$((_n + 1))
            fi
        done <<EOF
$(python3 "$PY" publish-list --root "$WTOOL_ROOT")
EOF
        [ "$_n" -gt 0 ] || wt_info "  （一个都没有）"
        wt_info "用 wtool download <项目> 下载其中一个；wtool download all 全部"
        return 0
    fi

    _targets=$(wt_expand_targets download $_targets)
    [ -n "$(printf '%s' "$_targets" | tr -d ' ')" ] || wt_die "没有匹配的项目（试试 wtool download 看有哪些）"

    _done=0
    for _want in $_targets; do
        _row=$(wt_publish_resolve "$_want") || exit $?
        _pid=$(printf '%s\n' "$_row" | cut -f2)
        _path=$(printf '%s\n' "$_row" | cut -f3)

        wt_info "── $_pid"
        if ! wt_project_script "$_path" download.sh >/dev/null 2>&1; then
            wt_warn "  没有 scripts/download.sh，这个项目只能自己编（wtool build $_pid）"
            continue
        fi
        WTOOL_PROJECT_ID=$_pid
        wt_info "  脚本 : scripts/download.sh"
        wt_run_project_script "$_path" download.sh || { wt_warn "  download.sh 失败，跳过"; continue; }
        wt_record_action "$_pid" download
        _done=$((_done + 1))
    done
    wt_info "download 完成（$_done 个项目）"
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
    wt_plan_exec "$_scratch/plan.tsv"

    if ! wt_dry; then
        cp -f -- "$_scratch/meta.tsv" "$WTOOL_META"
        printf 'installed_at\t%s\n' "$(wt_now)" >> "$WTOOL_META"
        printf 'engine\t%s\n' "$ENGINE_VERSION" >> "$WTOOL_META"
    fi

    # 项目自己的 install.sh 在这之后跑：
    #   1) wtool.xml 的 link/rc 是通用机制，先铺好，脚本才能依赖
    #      ~/.wtool/links/<id> 这个稳定地址；
    #   2) 项目特有的安装步骤（编好的东西怎么摆、shell 集成怎么加）
    #      只有项目自己知道，交给脚本。
    #
    # ⚠️ 正因为引擎会跑 install.sh，**项目里不能再放"调用 wtool install"的存根**，
    #    那会变成 install.sh → wtool install → install.sh 的无限递归。
    #    存根已经全部删除；需要自定义安装的项目才提供 install.sh。
    if [ "$_no_script" = 1 ]; then
        wt_info "跳过项目自己的 install.sh（--no-script）"
    elif wt_project_script "$_project" install.sh >/dev/null; then
        wt_info "项目脚本: install.sh"
        wt_run_project_script "$_project" install.sh || wt_die "install.sh 失败: $WTOOL_PROJECT_ID"
    fi

    # 全量重算环境变量汇总（用户的 rc 里始终只有一个 loader 块）
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
            --id)      shift; _id=${1:-} ;;
            -*)        wt_die "未知参数: $1" ;;
            *)         _project=$1 ;;
        esac
        shift
    done
    [ -n "$_project" ] || [ -n "$_id" ] || wt_die "用法: wtool.sh uninstall <项目目录>|--id <id>"

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

    # 2) 逆序回放 journal
    if [ -f "$WTOOL_JOURNAL" ]; then
        wt_journal_reverse | while IFS='	' read -r _action _kind _dest _target _sha; do
            [ -z "${_action:-}" ] && continue
            case $_action in
                link)
                    wt_link_remove "$_dest" "$_target"
                    wt_registry_del "$_dest"
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
                    # system-file 是可逆的：从备份还原（可能需要 root）
                    wt_sysfile_restore "$_kind" "$_dest" "$_target" "$_sha"
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

    # 4) 清理引擎自己的空目录
    #    多个项目共享 ~/.wtool/links 这类父目录，各自 journal 清不干净，
    #    这里统一做一次"只删空目录"的收尾（只动 .wtool/links，不碰 .wtool/usr）。
    if ! wt_dry; then
        if [ -d "$WTOOL_HOME/.wtool/links" ]; then
            find "$WTOOL_HOME/.wtool/links" -depth -type d -empty -delete 2>/dev/null || true
        fi
        rmdir -- "$WTOOL_HOME/.wtool" 2>/dev/null || true
    fi

    # 4.5) 重算环境变量汇总。必须在第 5 步之前：
    #      最后一个项目卸载完时，汇总文件要消失、loader 块要从 rc 里剥掉，
    #      剥完 rc 才可能变成空文件，第 5 步才有东西可删。
    wt_env_sync

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

    # 6) 清理状态目录（连带清掉空掉的父目录，例如 state/terminal）
    if ! wt_dry; then
        rm -rf -- "$WTOOL_PROJECT_DIR"
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
# provision：system-file → source → task
# 与 install 完全分离：install 只做可逆的软链/rc；这里做换源、拉源码、装包、编译
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

cmd_provision() {
    _project=""
    for arg in "$@"; do
        case $arg in
            --dry-run)     WTOOL_DRY_RUN=1 ;;
            --force)       WTOOL_FORCE=1 ;;
            --with-system) WTOOL_WITH_SYSTEM=1 ;;
            -*)            wt_die "未知参数: $arg" ;;
            *)             _project=$arg ;;
        esac
    done
    [ -n "$_project" ] || wt_die "用法: wtool.sh provision <项目目录> [--dry-run] [--force] [--with-system]"
    [ -d "$_project" ] || wt_die "项目目录不存在: $_project"
    _project=$(cd -- "$_project" && pwd)

    _scratch=$(mktemp -d "${TMPDIR:-/tmp}/wtool.XXXXXX")
    trap 'rm -rf -- "$_scratch"' EXIT INT TERM

    python3 "$PY" plan-provision "$_project" \
        --home "$WTOOL_HOME" --state "$WTOOL_STATE" --scratch "$_scratch" \
        --os-id "$WTOOL_OS_ID" --os-version "$WTOOL_OS_VERSION" \
        --os-codename "$WTOOL_OS_CODENAME" --arch "$WTOOL_ARCH" \
        --jobs "$WTOOL_JOBS" --prefix "$WTOOL_PREFIX" --src-root "$WTOOL_SRC" \
        $([ "$WTOOL_FORCE" = 1 ] && echo --force) || exit $?

    wt_load_project "$_scratch"
    wt_info "project: $WTOOL_PROJECT_ID"

    # 1) system-file（需要 root；默认不动系统）
    if [ -s "$_scratch/sysfiles.tsv" ]; then
        while IFS='	' read -r _mode _dest _content _sha _bak _desc; do
            [ -z "${_mode:-}" ] && continue
            if [ "${WTOOL_WITH_SYSTEM:-0}" != 1 ]; then
                wt_warn "跳过系统文件（需要 --with-system）: $_dest"
                continue
            fi
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

    wt_info "provision 完成"
}

# --------------------------------------------------------------------------
# bootstrap：把工作区里所有 wtool 项目按 priority 依次 provision + install
# --------------------------------------------------------------------------
cmd_bootstrap() {
    _no_system=0
    _install_only=0
    for arg in "$@"; do
        case $arg in
            --dry-run)      WTOOL_DRY_RUN=1 ;;
            --force)        WTOOL_FORCE=1 ;;
            --with-system)  WTOOL_WITH_SYSTEM=1 ;;
            --no-system)    _no_system=1 ;;
            --install-only) _install_only=1 ;;
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

    while IFS='	' read -r _prio _pid _path; do
        [ -z "${_pid:-}" ] && continue
        printf '\n=== [%s] %s (%s) ===\n' "$_prio" "$_pid" "$_path"
        _common=""
        [ "$WTOOL_FORCE" = 1 ] && _common="$_common --force"
        [ "$WTOOL_DRY_RUN" = 1 ] && _common="$_common --dry-run"
        _prov="$_common"
        [ "$WTOOL_WITH_SYSTEM" = 1 ] && [ "$_no_system" = 0 ] && _prov="$_prov --with-system"
        if [ "$_install_only" = 1 ]; then
            wt_info "(--install-only：跳过换源/装包/编译，只做软链与注入)"
        else
            # shellcheck disable=SC2086
            cmd_provision "$_path" $_prov || wt_die "provision 失败: $_pid"
        fi
        # 构建在安装之前：install.sh 负责"登记和收尾"，
        # 它需要的东西得先由 build.sh 生产出来。没有 build.sh 就跳过。
        if [ "$_install_only" = 0 ] && [ "$WTOOL_DRY_RUN" != 1 ] \
                && wt_project_script "$_path" build.sh >/dev/null; then
            # shellcheck disable=SC2086
            cmd_build "$_path" $_common || wt_die "build 失败: $_pid"
        fi
        # shellcheck disable=SC2086
        cmd_install "$_path" $_common || wt_die "install 失败: $_pid"
    done < "$_list"
    rm -f "$_list"
    wt_info "bootstrap 完成"
}

# --------------------------------------------------------------------------
# 其它命令
# --------------------------------------------------------------------------
cmd_list() {
    [ -f "$WTOOL_REGISTRY" ] || { wt_info "（registry 为空）"; return 0; }
    printf '%-12s %-8s %s\n' PROJECT KIND DEST
    awk -F'\t' '{printf "%-12s %-8s %s\n", $2, $3, $1}' "$WTOOL_REGISTRY"
}

cmd_status() {
    if [ $# -gt 0 ]; then
        _id=$(python3 "$PY" validate "$1" --home "$WTOOL_HOME" --state "$WTOOL_STATE" \
              >/dev/null 2>&1 && echo ok || echo fail)
        [ "$_id" = ok ] || { wt_warn "清单校验失败: $1"; return 1; }
    fi
    _bad=0
    if [ -f "$WTOOL_REGISTRY" ]; then
        while IFS='	' read -r _dest _id _kind; do
            [ -z "${_dest:-}" ] && continue
            if [ ! -L "$_dest" ]; then
                wt_warn "缺失: $_dest（项目 $_id）"
                _bad=$((_bad + 1))
            fi
        done < "$WTOOL_REGISTRY"
    fi
    [ "$_bad" -eq 0 ] && wt_info "所有登记的软链都在"
    return 0
}

cmd_doctor() {
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
    echo
    cmd_table --verbose --summary
}

# --------------------------------------------------------------------------
# wtool table —— 一行一个项目，一列一个能力
#
#   +  已经做了     -  能做但还没做（TODO）     .  这个项目没这项能力
# 用 ASCII 而不是 emoji/勾号：终端里算不准的字符宽会让整张表错位。
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
    printf '+ 已完成   - 待做(TODO)   . 无此能力\n'
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

    _c "# wtool 环境变量 —— 由 \`wtool env\` 生成"
    _c "# 立即生效： eval \"\$(wtool env)\""
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
    _with_build=0; _with_install=0; _with_publish=0
    while [ $# -gt 0 ]; do
        case $1 in
            --id)           shift; _id=${1:-} ;;
            --priority)     shift; _prio=${1:-} ;;
            --with-build)   _with_build=1 ;;
            --with-install) _with_install=1 ;;
            --with-publish) _with_publish=1 ;;
            --all)          _with_build=1; _with_install=1; _with_publish=1 ;;
            -*)             wt_die "未知参数: $1" ;;
            *)              _dir=$1 ;;
        esac
        shift
    done
    [ -n "$_dir" ] || wt_die "用法: wtool.sh init <目录> [--id ID] [--priority N] [--all]

  --with-build    生成 build.sh（能编译的项目）
  --with-install  生成 install.sh（有自己安装逻辑的项目）
  --with-publish  生成 publish.sh（发布时要跑脚本的项目）
  --all           三个都要

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
  wtool 只认下面这些元素，别的不认识的会直接报错（自定义的请用 x- 前缀）。
-->
<wtool schema="1" id="$_id" priority="$_prio">

  <!-- 被 shell source 的部分。加载器已经导出
       WTOOL_PROJECT_ID / WTOOL_PROJECT_DIR / WTOOL_PROJECT_ROOT -->
  <env src="env.zsh" shells="zsh,bash"/>

  <!-- src 相对本文件所在目录，dest 相对 \$HOME -->
  <!-- <link src="foo.conf" dest=".config/foo/foo.conf"/> -->

  <!-- 需要 apt / 编译 / 跑脚本的，用 provision（不可逆，和 install 分开） -->
  <!-- <provision src="provision/packages.yaml" marker="$_id-deps"/> -->

</wtool>
EOF
        wt_step "生成 wtool.xml"
    fi

    if [ ! -f "$_dir/env.zsh" ]; then
        cat > "$_dir/env.zsh" <<'EOF'
# 被 shell 的 wtool 托管块 source。
# 加载器已经导出：WTOOL_PROJECT_ID / WTOOL_PROJECT_DIR / WTOOL_PROJECT_ROOT
#
# 这里放这个项目需要的环境变量，例如：
#   export PATH="$WTOOL_PROJECT_DIR/bin:$PATH"
EOF
        wt_step "生成 env.zsh"
    fi

    _tpl_dir="$here/templates"
    _emit() {   # <脚本名> <说明>
        [ -f "$_dir/$1" ] && { wt_warn "$1 已存在，不动它"; return 0; }
        [ -f "$_tpl_dir/$1.tpl" ] || wt_die "缺少模板: $_tpl_dir/$1.tpl"
        sed "s|@PROJECT_ID@|$_id|g" "$_tpl_dir/$1.tpl" > "$_dir/$1"
        chmod +x -- "$_dir/$1"
        wt_step "生成 $1  ($2)"
    }
    [ "$_with_build" = 1 ]   && _emit build.sh   "能构建"
    [ "$_with_install" = 1 ] && _emit install.sh "能安装"
    [ "$_with_publish" = 1 ] && _emit publish.sh "能发布"

    wt_info "已生成项目: $_dir  (id=$_id priority=$_prio)"
    wt_info "下一步：填 wtool.xml，然后 wtool validate $_dir"
}

# --------------------------------------------------------------------------
# publish：把项目发布成 release 资产
#
# 行为由项目自己的 wtool.xml 决定：
#   没有 <publish> / kind="source"  → 引擎打源码包（第一层固定 wtool/），
#                                     推到项目 origin 的 release
#   kind="script" script="x.sh"     → 调项目内脚本；脚本产出，引擎上传
#   kind="none"                     → 不发布（第三方上游仓）
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
        0) wt_die "找不到项目: $_want（用 wtool publish 不带参数看全部）" ;;
        1) printf '%s\n' "$_hits" ;;
        *) wt_warn "「$_want」匹配到多个项目："
           printf '%s\n' "$_hits" | awk -F'\t' '{print "  " $2}' >&2
           wt_die "请写完整的项目 id" ;;
    esac
}

cmd_publish() {
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

    command -v gh >/dev/null 2>&1 || wt_die "publish 需要 gh（GitHub CLI）；装好再试"

    # --out=DIR 时产物最后拷到那里（先打出来看看再传）。
    # 内部中间文件（sel.tsv 之类）始终放在临时目录里，绝不混进产物目录——
    # 用户很可能直接 `gh release upload DIR/*`，把 sel.tsv 传上去就闹笑话了。
    if [ -n "$_outdir" ]; then
        mkdir -p -- "$_outdir" || wt_die "建不了目录: $_outdir"
        _outdir=$(cd -- "$_outdir" && pwd)
    fi
    _scratch=$(mktemp -d "${TMPDIR:-/tmp}/wtool-publish.XXXXXX")
    trap 'rm -rf -- "$_scratch"' EXIT INT TERM

    # 1) 决定发布哪些项目
    : > "$_scratch/sel.tsv"
    if [ -n "$_want" ]; then
        for w in $_want; do
            wt_publish_resolve "$w" >> "$_scratch/sel.tsv" || exit $?
        done
        # 同一个项目写了两次就只发一次
        _tmp="$_scratch/sel.dedup"
        awk -F'\t' '!seen[$2]++' "$_scratch/sel.tsv" > "$_tmp" && mv -f "$_tmp" "$_scratch/sel.tsv"
    else
        python3 "$PY" publish-list --root "$WTOOL_ROOT" > "$_scratch/sel.tsv"
    fi

    if [ ! -s "$_scratch/sel.tsv" ]; then
        wt_die "没有任何项目声明了 publish"
    fi

    # 上一轮 publish 在结尾重写过带下载块的文档，于是那个文件是"未提交"的。
    # 不豁免的话，下一次 publish 就会以"有未提交改动"把文档项目跳过 ——
    # 一次发布把下一次发布搞坏，自噬。这里只豁免**那一个文件**，
    # 而且必须它的改动只涉及这个文件才放行。
    _doc_path=$(grep -rl --include='*.md' -F '<!-- >>> wtool:downloads >>>' \
                    "$WTOOL_ROOT" 2>/dev/null | head -1)

    _done=0
    # 清单走 fd 3，不走 stdin。脚本自己（或它调用的 docker/gh）读 stdin 是常事，
    # 从 stdin 读清单会被它们偷走行，表现是后面的项目被静默跳过。
    exec 3< "$_scratch/sel.tsv"
    while IFS='	' read -r _prio _pid _path _kind _script _tpl _to <&3; do
        [ -n "${_pid:-}" ] || continue
        _date=$(date +%Y-%m-%d)
        if [ -n "$_tag_override" ]; then _tag=$_tag_override; else _tag=$(wt_publish_tag "$_tpl"); fi

        wt_info "── $_pid  [$(_publish_kind_cn "$_kind")]"

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
            # 注意：不能写 `_perm=$(...)` 后紧跟 `_rc=$?`。
            # set -e 下"只含赋值的简单命令"会继承命令替换的退出码，
            # 非 0 就直接静默退出——保护逻辑没生效，整个发布却无声中断了。
            # 放进 || 列表里才安全。
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

        if [ "$_kind" = "script" ]; then
            _script_path=$_path/$_script
            if [ ! -f "$_script_path" ]; then
                wt_warn "  脚本不存在: $_script_path，跳过"
                continue
            fi
            _out=$_scratch/out-$_done
            rm -rf -- "$_out"; mkdir -p -- "$_out"

            wt_info "  脚本   : $_script"
            if wt_dry; then
                wt_step "[dry-run] 执行 $_script（产出目录 $_out）"
                wt_step "[dry-run] 之后把 $_out 里的文件传到 $_repo $_tag"
                _done=$((_done + 1))
                continue
            fi

            (
                export WTOOL_PUBLISH_PROJECT="$_pid"
                export WTOOL_PUBLISH_ROOT="$_path"
                export WTOOL_PUBLISH_WS="$WTOOL_ROOT"
                export WTOOL_PUBLISH_REPO="$_repo"
                export WTOOL_PUBLISH_TAG="$_tag"
                export WTOOL_PUBLISH_OUT="$_out"
                export WTOOL_PUBLISH_FORCE="${WTOOL_FORCE:-0}"
                export WTOOL_PUBLISH_DATE="$_date"
                cd -- "$_path" || exit 1
                sh "$_script_path"
            ) || { wt_warn "  $_script 失败，跳过上传"; continue; }

            _files=$(find "$_out" -maxdepth 1 -type f | sort)
            _n=$(printf '%s' "$_files" | grep -c . || true)
            if [ "$_n" = 0 ]; then
                wt_info "  脚本没有产出文件（可能自己上传了），到此为止"
                continue
            fi
            wt_publish_gh_release "$_repo" "$_tag" "$_pid $_date" \
                "由 wtool publish 生成。目标系统与内容见 dist.json。"
            # shellcheck disable=SC2086
            wt_publish_gh_upload "$_repo" "$_tag" $_files
            wt_publish_record "$_pid" "$_repo" "$_tag" "$_n" "script:$_script"
            _done=$((_done + 1))
            continue
        fi

        # kind=source
        if ! git -C "$_path" rev-parse --git-dir >/dev/null 2>&1; then
            wt_warn "  $_path 不是 git 仓库，无法确定版本，跳过（用 --force 也推不出有意义的包）"
            continue
        fi
        _dirty=$(git -C "$_path" status --porcelain 2>/dev/null || true)
        if [ -n "$_dirty" ] && [ -n "$_doc_path" ]; then
            case $_doc_path in
                "$_path"/*)
                    _doc_rel=${_doc_path#"$_path"/}
                    # 只看"除了那个文档之外还有没有别的改动"
                    _other=$(printf '%s\n' "$_dirty" | awk -v d="$_doc_rel" '$NF != d')
                    if [ -z "$_other" ]; then
                        wt_info "  只有自动生成的下载块变了，按干净处理（记得提交 $_doc_rel）"
                        _dirty=""
                    fi
                    ;;
            esac
        fi
        if [ "${WTOOL_FORCE:-0}" != 1 ] && [ -n "$_dirty" ]; then
            wt_warn "  $_path 有未提交改动，拒绝发布（先提交，或加 --force）"
            continue
        fi

        _commit=$(git -C "$_path" rev-parse HEAD 2>/dev/null || echo "")
        _dirty=0
        [ -n "$(git -C "$_path" status --porcelain 2>/dev/null)" ] && _dirty=1
        _dashed=$(printf '%s' "$_pid" | tr '/' '-')
        _asset="$_dashed-$_date.tar.$(wt_pack_ext)"

        # 发布副本标记：解压后 install 不必加 --force，head 也从这里取
        mkdir -p -- "$_scratch/dist/.wtool-dist"
        cat > "$_scratch/dist/.wtool-dist/$_dashed.json" <<EOF
{
  "project": "$_pid",
  "repo": "$_repo",
  "commit": "$_commit",
  "dirty": $([ "$_dirty" = 1 ] && echo true || echo false),
  "packed_at": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "view": "release",
  "layout": "wtool/$_pid"
}
EOF

        _out=$_scratch/out-$_done
        wt_pack_source "$_path" "$_out/$_asset" "$_scratch/dist" ".wtool-dist/$_dashed.json" \
            || exit $?
        wt_info "  资产   : $_asset  (commit $(printf '%s' "$_commit" | cut -c1-7), dirty=$_dirty)"
        wt_publish_gh_release "$_repo" "$_tag" "$_pid $_date" \
            "由 wtool publish 生成。解压到工作区上一层即可（包内第一层是 wtool/）。"
        wt_publish_gh_upload "$_repo" "$_tag" "$_out/$_asset"
        wt_publish_record "$_pid" "$_repo" "$_tag" 1 "source:$_commit"
        _done=$((_done + 1))
    done
    exec 3<&-

    # 产物交付给 --out（如果指定了）
    if [ -n "${_outdir:-}" ] && ! wt_dry; then
        _copied=0
        for _d in "$_scratch"/out-*; do
            [ -d "$_d" ] || continue
            for _f in "$_d"/*; do
                [ -f "$_f" ] || continue
                cp -f -- "$_f" "$_outdir/" && _copied=$((_copied + 1))
            done
        done
        [ "$_copied" -gt 0 ] && wt_info "产物已放到 $_outdir（$_copied 个文件）"
    fi

    wt_refresh_downloads

    if [ "$_done" = 0 ] && ! wt_dry; then
        wt_warn "没有发布任何项目"
    fi
    if wt_dry; then
        wt_info "publish 计划完成（$_done 个项目）"
    else
        wt_info "publish 完成（$_done 个项目）"
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
    _doc=$(grep -rl --include='*.md' -F '<!-- >>> wtool:downloads >>>' \
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
        script) printf '脚本' ;;
        none)   printf '不发布' ;;
        *)      printf '%s' "$1" ;;
    esac
}

# --------------------------------------------------------------------------
# 分发
# --------------------------------------------------------------------------
_cmd=${1:-}
[ $# -gt 0 ] && shift

case $_cmd in
    build)     cmd_build "$@" ;;
    download)  cmd_download "$@" ;;
    install)   cmd_install "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    provision) cmd_provision "$@" ;;
    publish)   cmd_publish "$@" ;;
    bootstrap) cmd_bootstrap "$@" ;;
    list)      cmd_list "$@" ;;
    table)     cmd_table "$@" ;;
    status)    cmd_status "$@" ;;
    doctor)    cmd_doctor "$@" ;;
    env)       cmd_env "$@" ;;
    init)      cmd_init "$@" ;;
    scaffold)  wt_warn "scaffold 已改名为 init，请用 wtool init"; cmd_init "$@" ;;
    validate)  python3 "$PY" validate "$@" --home "$WTOOL_HOME" --state "$WTOOL_STATE" ;;
    version)   echo "wtool engine $ENGINE_VERSION" ;;
    -h|--help|help)
        # 打印文件头的注释块，不写死行号（否则加一行用法就错位）
        awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$self"
        ;;
    "")
        # 不带参数 = 看板：哪些项目装过、provision 过、发布过
        cmd_table --verbose --summary
        ;;
    *) wt_die "未知命令: $_cmd（用 --help 查看用法）" ;;
esac
