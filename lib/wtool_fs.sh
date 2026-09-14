#!/bin/sh
# wtool 执行层 —— 唯一允许修改 $HOME 的地方。
#
# 契约（见 docs/spec.md §3）：
#   * 所有对 $HOME 的写操作都经过本文件的函数
#   * 每个动作都要么记入 journal（可逆），要么本身就是只读检查
#   * 支持 WTOOL_DRY_RUN=1 时零副作用
#
# 由 wtool.sh source 使用，不单独执行。

# --------------------------------------------------------------------------
# 日志
# --------------------------------------------------------------------------
wt_info()  { printf 'wtool: %s\n' "$*"; }
wt_warn()  { printf 'wtool: warning: %s\n' "$*" >&2; }
wt_die()   { printf 'wtool: error: %s\n' "$*" >&2; exit 1; }
wt_step()  { printf 'wtool:   - %s\n' "$*"; }

wt_dry()   { [ "${WTOOL_DRY_RUN:-0}" = 1 ]; }
wt_run() {
    if wt_dry; then
        wt_step "[dry-run] $*"
    else
        "$@" || wt_die "命令失败: $*"
    fi
}

# --------------------------------------------------------------------------
# journal：install 做过什么，uninstall 就逆着做
# 格式: action \t kind \t dest \t target \t sha256
# --------------------------------------------------------------------------
wt_journal_add() {
    wt_dry && return 0
    _ja=$1; _jk=$2; _jd=$3; _jt=${4:--}; _js=${5:--}
    # 按 (action, dest) 去重：journal 描述"当前该撤销什么"，
    # 所以重复 install 只是更新记录，不会堆积重复项，也绝不会被清空。
    _tmp="$WTOOL_JOURNAL.tmp.$$"
    if [ -f "$WTOOL_JOURNAL" ]; then
        awk -F'\t' -v a="$_ja" -v d="$_jd" '!($1 == a && $3 == d)' \
            "$WTOOL_JOURNAL" > "$_tmp" && mv -f -- "$_tmp" "$WTOOL_JOURNAL"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$_ja" "$_jk" "$_jd" "$_jt" "$_js" \
        >> "$WTOOL_JOURNAL"
}

wt_journal_reverse() {
    # 逆序输出 journal（跳过注释与空行）
    [ -f "$WTOOL_JOURNAL" ] || return 0
    grep -v '^#' "$WTOOL_JOURNAL" | sed '/^$/d' | tac 2>/dev/null \
        || grep -v '^#' "$WTOOL_JOURNAL" | sed '/^$/d' | tail -r
}

# --------------------------------------------------------------------------
# registry：全局登记 dest -> 项目，用来发现跨项目冲突
# 格式: dest \t project_id \t kind
# --------------------------------------------------------------------------
wt_registry_set() {
    _dest=$1; _id=$2; _kind=$3
    wt_dry && return 0
    [ -f "$WTOOL_REGISTRY" ] || : > "$WTOOL_REGISTRY"
    _tmp="$WTOOL_REGISTRY.tmp.$$"
    awk -F'\t' -v d="$_dest" '$1 != d' "$WTOOL_REGISTRY" > "$_tmp"
    printf '%s\t%s\t%s\n' "$_dest" "$_id" "$_kind" >> "$_tmp"
    mv -f -- "$_tmp" "$WTOOL_REGISTRY"
}

wt_registry_del() {
    _dest=$1
    wt_dry && return 0
    [ -f "$WTOOL_REGISTRY" ] || return 0
    _tmp="$WTOOL_REGISTRY.tmp.$$"
    awk -F'\t' -v d="$_dest" '$1 != d' "$WTOOL_REGISTRY" > "$_tmp"
    mv -f -- "$_tmp" "$WTOOL_REGISTRY"
}

# --------------------------------------------------------------------------
# 目录
# --------------------------------------------------------------------------
wt_ensure_dir() {
    _d=$1
    [ -d "$_d" ] && return 0
    _stack=""
    _cur=$_d
    while [ ! -d "$_cur" ]; do
        _stack="$_cur|$_stack"
        _parent=$(dirname -- "$_cur")
        [ "$_parent" = "$_cur" ] && break
        _cur=$_parent
    done
    wt_run mkdir -p -- "$_d"
    _old_ifs=$IFS
    IFS='|'
    for _m in $_stack; do
        IFS=$_old_ifs
        [ -n "$_m" ] && wt_journal_add mkdir dir "$_m"
        IFS='|'
    done
    IFS=$_old_ifs
}

wt_remove_dir_if_empty() {
    _d=$1
    [ -d "$_d" ] || return 0
    if [ -z "$(ls -A -- "$_d" 2>/dev/null)" ]; then
        wt_run rmdir -- "$_d" 2>/dev/null || true
    fi
}

# --------------------------------------------------------------------------
# 软链
# --------------------------------------------------------------------------
wt_journal_owns() {
    # 这条记录是不是我们自己建的？（用于区分"我们的旧链接"和"别人的链接"）
    _act=$1; _d=$2
    [ -f "${WTOOL_JOURNAL:-}" ] || return 1
    awk -F'\t' -v a="$_act" -v d="$_d" \
        '$1 == a && $3 == d { found = 1 } END { exit !found }' "$WTOOL_JOURNAL"
}

wt_link_create() {
    _dest=$1; _target=$2
    if [ -L "$_dest" ]; then
        _cur=$(readlink -- "$_dest")
        if [ "$_cur" = "$_target" ]; then
            return 0                      # 已经是我们要的，幂等
        fi
        if [ "${WTOOL_FORCE:-0}" = 1 ]; then
            wt_warn "覆盖已存在的软链: $_dest -> $_cur"
            wt_run rm -f -- "$_dest"
        elif wt_journal_owns link "$_dest"; then
            # 我们自己建的链接，但目标变了（典型场景：仓库搬了家）
            wt_info "更新软链: $_dest -> $_target（原 $_cur）"
            wt_run rm -f -- "$_dest"
        else
            wt_die "dest 已是软链且指向别处: $_dest -> $_cur（用 --force 覆盖）"
        fi
    elif [ -e "$_dest" ]; then
        if [ "${WTOOL_FORCE:-0}" = 1 ]; then
            _bak="$_dest.wtool-bak.$(date +%Y%m%d%H%M%S)"
            wt_warn "备份已存在的文件: $_dest -> $_bak"
            wt_run mv -f -- "$_dest" "$_bak"
            wt_journal_add backup file "$_dest" "$_bak"
        else
            wt_die "dest 已存在且不是软链: $_dest（用 --force 备份后接管）"
        fi
    fi
    wt_ensure_dir "$(dirname -- "$_dest")"
    wt_run ln -s -- "$_target" "$_dest"
    wt_journal_add link file "$_dest" "$_target"
}

wt_link_remove() {
    _dest=$1; _expected=$2
    if [ ! -L "$_dest" ]; then
        if [ -e "$_dest" ]; then
            wt_warn "跳过（已不是软链，可能是你的真实文件）: $_dest"
        fi
        return 0
    fi
    _cur=$(readlink -- "$_dest")
    if [ "$_expected" != "-" ] && [ "$_cur" != "$_expected" ]; then
        wt_warn "跳过（软链指向已变）: $_dest -> $_cur（期望 $_expected）"
        return 0
    fi
    wt_run rm -f -- "$_dest"
}

# --------------------------------------------------------------------------
# 原子写文件（跟随软链，绝不把软链替换成普通文件）
# --------------------------------------------------------------------------
wt_atomic_write() {
    _dest=$1; _src=$2
    if [ -L "$_dest" ]; then
        _real=$(readlink -f -- "$_dest" 2>/dev/null) || _real=$_dest
    else
        _real=$_dest
    fi
    wt_ensure_dir "$(dirname -- "$_real")"
    if wt_dry; then
        wt_step "[dry-run] 写文件 $_real（内容来自 $_src）"
        return 0
    fi
    _tmp="$_real.wtool.tmp.$$"
    cp -f -- "$_src" "$_tmp" || wt_die "写入临时文件失败: $_tmp"
    if [ -e "$_real" ]; then
        chmod --reference="$_real" "$_tmp" 2>/dev/null || true
    fi
    mv -f -- "$_tmp" "$_real" || wt_die "替换失败: $_real"
}

# --------------------------------------------------------------------------
# 全局记录：哪些 rc 文件是 wtool 创建的
# （多个项目都往同一个 ~/.zshrc 写块，只有最后卸载的那个才知道它已空）
# --------------------------------------------------------------------------
wt_created_rc_add() {
    wt_dry && return 0
    _list="$WTOOL_STATE/created-rc.tsv"
    mkdir -p -- "$WTOOL_STATE"
    grep -qxF -- "$1" "$_list" 2>/dev/null || printf '%s\n' "$1" >> "$_list"
}

# --------------------------------------------------------------------------
# 执行 py 生成的 plan.tsv
# --------------------------------------------------------------------------
wt_plan_exec() {
    _plan=$1
    [ -f "$_plan" ] || wt_die "plan 不存在: $_plan"
    while IFS='	' read -r _action _kind _dest _source _sha _extra; do
        [ -z "${_action:-}" ] && continue
        case $_action in
            reg)
                # 只登记，不改文件系统（软链已存在且正确时走这里）
                wt_registry_set "$_dest" "$WTOOL_PROJECT_ID" "$_kind"
                ;;
            link)
                wt_link_create "$_dest" "$_source"
                wt_registry_set "$_dest" "$WTOOL_PROJECT_ID" "$_kind"
                ;;
            rc)
                # 记下"这个 rc 文件本来不存在，是我们创建的"，卸载时好还原
                if [ ! -e "$_dest" ]; then
                    wt_journal_add rccreate file "$_dest"
                    wt_created_rc_add "$_dest"
                fi
                wt_atomic_write "$_dest" "$_source"
                wt_journal_add rc file "$_dest" "-" "$_extra"
                ;;
            *)
                wt_die "未知动作: $_action"
                ;;
        esac
    done < "$_plan"
}

# ==========================================================================
# provision 相关（system-file / source / task）
# 约定：这里的操作**不进 install**，由 `wtool provision` 显式触发。
#   * system-file 可逆 → 记 journal，uninstall 时还原
#   * source / task  不可逆 → 只记日志与 marker，不参与 uninstall
# ==========================================================================

# 需要 root 时统一走这里（容器里是 root 就直接跑；否则用 sudo）
wt_as_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        wt_die "需要 root 权限但没有 sudo: $*"
    fi
}

# 从目标路径向上找到最近的存在祖先，判断当前用户能否写
wt_can_write() {
    _p=$1
    while [ ! -e "$_p" ]; do
        _parent=$(dirname -- "$_p")
        [ "$_parent" = "$_p" ] && break
        _p=$_parent
    done
    [ -w "$_p" ]
}

# 写系统文件时的提权判断：能直接写就不 sudo
# （容器里是 root、测试里 dest 在用户目录、或用户本来就有权限时都走这条）
wt_sysfile_run() {
    _dest=$1
    shift
    if [ "$(id -u)" = 0 ] || wt_can_write "$_dest"; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        wt_die "需要 root 才能操作 $_dest（且没有 sudo）"
    fi
}

wt_sysfile_slug() {
    printf '%s' "$1" | sed 's|^/||; s|/|_|g'
}

# 写系统文件：备份 → 写入 → 记 journal
wt_sysfile_apply() {
    _mode=$1; _dest=$2; _content=$3; _sha=$4; _backup=$5; _desc=$6
    _dir="$WTOOL_STATE/$WTOOL_PROJECT_ID/system/$(wt_sysfile_slug "$_dest")"
    _orig="$_dir/original"

    if [ "$_mode" = disable ]; then
        if [ ! -e "$_dest" ]; then
            wt_warn "disable 的目标不存在，跳过: $_dest"
            return 0
        fi
        wt_run wt_sysfile_run "$_dest" mv -- "$_dest" "$_dest.wtool-disabled"
        wt_journal_add sysfile disable "$_dest" "$_dest.wtool-disabled" "-"
        return 0
    fi

    _bak="-"
    if [ -e "$_dest" ]; then
        if [ "$_backup" = yes ]; then
            if wt_dry; then
                wt_step "[dry-run] 备份 $_dest -> $_orig"
            else
                wt_ensure_dir "$_dir"
                wt_sysfile_run "$_dest" cp -f -- "$_dest" "$_orig" || wt_die "备份失败: $_dest"
                printf '%s\n' "$_dest" > "$_dir/dest"
                _bak="$_orig"
            fi
        elif [ "$_mode" = add ]; then
            wt_die "dest 已存在，且这条规则 backup=no / mode=add: $_dest"
        fi
    fi

    if wt_dry; then
        wt_step "[dry-run] 写系统文件 $_dest"
    else
        wt_sysfile_run "$_dest" mkdir -p -- "$(dirname -- "$_dest")"
        _tmp="$_dest.wtool.tmp.$$"
        wt_sysfile_run "$_dest" cp -f -- "$_content" "$_tmp" || wt_die "写入失败: $_tmp"
        wt_sysfile_run "$_dest" chmod 644 -- "$_tmp" 2>/dev/null || true
        wt_sysfile_run "$_dest" mv -f -- "$_tmp" "$_dest" || wt_die "替换失败: $_dest"
    fi
    wt_journal_add sysfile "$_mode" "$_dest" "$_bak" "$_sha"
}

# 还原系统文件（uninstall 时由 journal 触发）
wt_sysfile_restore() {
    _mode=$1; _dest=$2; _bak=$3; _sha=$4
    case $_mode in
        disable)
            if [ -e "$_bak" ] && [ ! -e "$_dest" ]; then
                wt_run wt_sysfile_run "$_dest" mv -- "$_bak" "$_dest"
            fi
            ;;
        replace|add)
            if [ -n "$_bak" ] && [ "$_bak" != "-" ] && [ -f "$_bak" ]; then
                if wt_dry; then
                    wt_step "[dry-run] 还原 $_dest"
                else
                    _tmp="$_dest.wtool.restore.$$"
                    wt_sysfile_run "$_dest" cp -f -- "$_bak" "$_tmp" || wt_die "还原失败: $_dest"
                    wt_sysfile_run "$_dest" mv -f -- "$_tmp" "$_dest"
                fi
            elif [ -f "$_dest" ]; then
                _cur=$(sha256sum -- "$_dest" 2>/dev/null | cut -d' ' -f1)
                if [ "$_cur" = "$_sha" ] || [ "${WTOOL_FORCE:-0}" = 1 ]; then
                    wt_run wt_sysfile_run "$_dest" rm -f -- "$_dest"
                else
                    wt_warn "跳过（文件内容已被改动）: $_dest"
                fi
            fi
            ;;
    esac
}

# 判断"脏文件是否全部来自 overlay"（我们上次铺进去的那些）
wt_overlay_only_dirty() {
    _dir=$1; _ov=$2
    [ -d "$_ov" ] || return 1
    git -C "$_dir" status --porcelain 2>/dev/null | while IFS= read -r _line; do
        _p=$(printf '%s' "$_line" | sed 's/^...//')
        case $_p in *" -> "*) _p=${_p##* -> } ;; esac
        [ -e "$_ov/$_p" ] || exit 1
    done
}

# 同步上游源码：clone/fetch → 固定 ref → 建/重置本地分支 → 铺 overlay → 提交到 wsw 分支
wt_source_sync() {
    _dir=$1; _url=$2; _ref=$3; _branch=$4; _overlay=$5
    if wt_dry; then
        wt_step "[dry-run] source: $_url @ $_ref -> $_dir（分支 $_branch）"
        return 0
    fi

    if [ -d "$_dir/.git" ]; then
        wt_run git -C "$_dir" fetch --tags --prune origin
        if [ -n "$(git -C "$_dir" status --porcelain 2>/dev/null)" ]; then
            if [ "${WTOOL_FORCE:-0}" = 1 ] || wt_overlay_only_dirty "$_dir" "$_overlay"; then
                wt_info "丢弃源码树里的本地改动（重新铺 overlay）"
                wt_run git -C "$_dir" checkout -f --detach "$_ref"
            else
                wt_die "源码树有非 overlay 的本地改动: $_dir（请自行处理，或加 --force）"
            fi
        fi
    else
        wt_ensure_dir "$(dirname -- "$_dir")"
        wt_run git clone --no-single-branch -- "$_url" "$_dir"
        wt_journal_add srcdir dir "$_dir" "-" "-"
    fi

    wt_run git -C "$_dir" checkout --detach "$_ref"
    wt_run git -C "$_dir" checkout -B "$_branch"

    if [ -n "$_overlay" ] && [ -d "$_overlay" ]; then
        wt_run cp -a -- "$_overlay/." "$_dir/"
        # 把 overlay 提交到 wsw 分支：这样 wsw 分支就是"上游 + 我的改动"，
        # 下次运行工作区是干净的，git diff 也才有意义
        if [ -n "$(git -C "$_dir" status --porcelain 2>/dev/null)" ]; then
            wt_run git -C "$_dir" add -A
            wt_run git -C "$_dir" -c user.email=wtool@localhost -c user.name=wtool \
                commit -q -m "wtool: overlay on $_ref"
        fi
        wt_info "overlay 已铺入并提交到分支 $_branch: $_dir"
    fi

    WTOOL_SOURCE_DIR="$_dir"
    WTOOL_SOURCE_REF="$_ref"
    export WTOOL_SOURCE_DIR WTOOL_SOURCE_REF
}

# 执行一个 provision 任务（ansible 或 shell），带幂等 marker
wt_task_run() {
    _runner=$1; _src=$2; _marker=$3; _desc=$4; _cwd=$5
    _mfile="$WTOOL_STATE/$WTOOL_PROJECT_ID/provisioned/$_marker"

    if [ -n "$_marker" ] && [ -f "$_mfile" ] && [ "${WTOOL_FORCE:-0}" != 1 ]; then
        wt_info "已装过（marker=$_marker），跳过: $_desc"
        return 0
    fi
    if wt_dry; then
        wt_step "[dry-run] task[$_runner]: $_desc"
        return 0
    fi
    [ -d "$_cwd" ] || _cwd="$WTOOL_PROJECT_ROOT"

    wt_ensure_dir "$WTOOL_PREFIX"
    (
        export WTOOL_PREFIX WTOOL_OS_ID WTOOL_OS_VERSION WTOOL_OS_CODENAME WTOOL_OS_LIKE
        export WTOOL_ARCH WTOOL_JOBS
        export WTOOL_PROJECT_ID WTOOL_PROJECT_DIR WTOOL_PROJECT_ROOT
        # 无人值守：debconf 的交互提问会把任务挂死（容器里没人回答）
        DEBIAN_FRONTEND=noninteractive
        export DEBIAN_FRONTEND
        export WTOOL_SOURCE_DIR="${WTOOL_SOURCE_DIR:-}"
        export WTOOL_SOURCE_REF="${WTOOL_SOURCE_REF:-}"
        cd "$_cwd" || exit 1
        case $_runner in
            ansible)
                command -v ansible-playbook >/dev/null 2>&1 \
                    || wt_die "缺少 ansible-playbook（sudo apt-get install -y --no-install-recommends ansible-core）"
                ansible-playbook -i localhost, -c local "$_src"
                ;;
            *)
                sh -e "$_src"
                ;;
        esac
    ) || wt_die "provision 任务失败: $_desc"

    if [ -n "$_marker" ]; then
        mkdir -p -- "$(dirname -- "$_mfile")"
        : > "$_mfile"
        printf '%s\t%s\n' "$_marker" "$(date +%Y-%m-%dT%H:%M:%S%z)" \
            >> "$WTOOL_STATE/$WTOOL_PROJECT_ID/provision.log"
    fi
}
