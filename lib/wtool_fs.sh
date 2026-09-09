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
                wt_atomic_write "$_dest" "$_source"
                wt_journal_add rc file "$_dest" "-" "$_extra"
                ;;
            *)
                wt_die "未知动作: $_action"
                ;;
        esac
    done < "$_plan"
}
