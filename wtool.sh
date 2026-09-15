#!/bin/sh
# wtool —— wtool 集合的引擎（唯一一份，住在 wtool-bootstrap 里）
#
#   wtool.sh install   <项目目录> [--dry-run] [--force]
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
#   wtool.sh scaffold  <目录> [--id ID]
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
WTOOL_ROOT=${WTOOL_ROOT:-$(dirname -- "$here")}
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

wt_git_precheck() {
    _dir=$1
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
# install
# --------------------------------------------------------------------------
cmd_install() {
    _project=""
    for arg in "$@"; do
        case $arg in
            --dry-run) WTOOL_DRY_RUN=1 ;;
            --force)   WTOOL_FORCE=1 ;;
            -*)        wt_die "未知参数: $arg" ;;
            *)         _project=$arg ;;
        esac
    done
    [ -n "$_project" ] || wt_die "用法: wtool.sh install <项目目录> [--dry-run] [--force]"
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

cmd_scaffold() {
    _dir=""; _id=""
    while [ $# -gt 0 ]; do
        case $1 in
            --id) shift; _id=${1:-} ;;
            -*)   wt_die "未知参数: $1" ;;
            *)    _dir=$1 ;;
        esac
        shift
    done
    [ -n "$_dir" ] || wt_die "用法: wtool.sh scaffold <目录> [--id ID]"
    [ -n "$_id" ] || _id=$(basename -- "$(cd -- "$_dir" 2>/dev/null && pwd || echo "$_dir")")
    mkdir -p -- "$_dir"
    [ -f "$_dir/wtool.xml" ] || cat > "$_dir/wtool.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="$_id" priority="100">
  <!-- 被 source 的部分；shells 省略时按扩展名推断 -->
  <env src="env.zsh" shells="zsh"/>

  <!-- src 相对本目录，dest 相对 \$HOME -->
  <!-- <link src="some.conf" dest=".some.conf"/> -->
</wtool>
EOF
    [ -f "$_dir/env.zsh" ] || cat > "$_dir/env.zsh" <<'EOF'
# 被 ~/.zshrc 的 wtool 块 source。
# 加载器已导出：WTOOL_PROJECT_ID / WTOOL_PROJECT_DIR / WTOOL_PROJECT_ROOT
EOF
    _tpl="$here/templates/stub.sh"
    [ -f "$_tpl" ] || wt_die "缺少模板: $_tpl"
    for stub in install.sh uninstall.sh; do
        [ -f "$_dir/$stub" ] && continue
        cp -f -- "$_tpl" "$_dir/$stub"
        chmod +x -- "$_dir/$stub"
    done
    wt_info "已生成脚手架: $_dir"
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

    # --out=DIR 时产物留在那里（先打出来看看再传），否则用临时目录
    if [ -n "$_outdir" ]; then
        mkdir -p -- "$_outdir" || wt_die "建不了目录: $_outdir"
        _scratch=$(cd -- "$_outdir" && pwd)
    else
        _scratch=$(mktemp -d "${TMPDIR:-/tmp}/wtool-publish.XXXXXX")
        trap 'rm -rf -- "$_scratch"' EXIT INT TERM
    fi

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
        if [ "${WTOOL_FORCE:-0}" != 1 ] && [ -n "$(git -C "$_path" status --porcelain 2>/dev/null)" ]; then
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

    if [ "$_done" = 0 ] && ! wt_dry; then
        wt_warn "没有发布任何项目"
    fi
    if wt_dry; then
        wt_info "publish 计划完成（$_done 个项目）"
    else
        wt_info "publish 完成（$_done 个项目）"
    fi
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
    scaffold)  cmd_scaffold "$@" ;;
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
