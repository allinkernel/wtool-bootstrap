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
    # 没有项目上下文（如 publish 只借用了 wt_ensure_dir）就不记账：
    # journal 描述的是"uninstall 该撤销什么"，publish 没有可撤销的东西。
    [ -n "${WTOOL_JOURNAL:-}" ] || return 0
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
                # 老版本写在用户 rc 里的块。现在只用于迁移清理，
                # 不再有新的写入走这条路。
                if [ ! -e "$_dest" ]; then
                    wt_journal_add rccreate file "$_dest"
                    wt_created_rc_add "$_dest"
                fi
                wt_atomic_write "$_dest" "$_source"
                wt_journal_add rc file "$_dest" "-" "$_extra"
                ;;
            envblock)
                # 项目的环境变量块，落在状态目录里（不是用户的 rc）
                wt_ensure_dir "$(dirname -- "$_dest")"
                wt_atomic_write "$_dest" "$_source"
                ;;
            envblock-del)
                [ -e "$_dest" ] && rm -f -- "$_dest"
                ;;
            write)
                # 汇总文件 / 用户 rc 的新内容
                wt_ensure_dir "$(dirname -- "$_dest")"
                wt_atomic_write "$_dest" "$_source"
                ;;
            remove)
                # 一个项目都没装了：汇总文件和 loader 块都该消失，
                # 让用户的 rc 回到没装过 wtool 的样子
                [ -e "$_dest" ] && rm -f -- "$_dest"
                wt_remove_dir_if_empty "$(dirname -- "$_dest")"
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

# --------------------------------------------------------------------------
# publish：把项目打成 release 资产
#
# 源码包的第一层目录名固定是 wtool/，跟本机工作区目录叫什么无关：
#   tar -C "$WTOOL_ROOT" --transform='s|^|wtool/|' ... terminal/tmux
#   → wtool/terminal/tmux/bin/net.sh ...
# 解压到 ~/self/ 之后路径和 repo sync 出来的完全一样。
# --------------------------------------------------------------------------

# 项目 origin 属于哪个仓：ssh://git@github.com/o/r.git / git@github.com:o/r.git
# / https://github.com/o/r.git 都归一到 o/r
#
# 注意 remote 名字：repo 客户端按 manifest 里的 remote name 命名，通常是 github
# 而不是 origin；手工 clone 的才是 origin。两种都要认。
wt_publish_repo_of() {
    _wtpub_dir=$1
    _wtpub_url=""
    for _wtpub_r in origin github upstream; do
        _wtpub_url=$(git -C "$_wtpub_dir" remote get-url "$_wtpub_r" 2>/dev/null || true)
        [ -n "$_wtpub_url" ] && break
        _wtpub_url=""
    done
    if [ -z "$_wtpub_url" ]; then
        # 兜底：只有一个 remote 就用它，多个就没法猜了
        _wtpub_remotes=$(git -C "$_wtpub_dir" remote 2>/dev/null || true)
        _wtpub_n=$(printf '%s\n' "$_wtpub_remotes" | grep -c . || true)
        [ "$_wtpub_n" = 1 ] && _wtpub_url=$(git -C "$_wtpub_dir" remote get-url "$_wtpub_remotes" 2>/dev/null || true)
    fi
    [ -n "$_wtpub_url" ] || return 1
    _wtpub_u=${_wtpub_url%.git}
    case "$_wtpub_u" in
        *://*)  _wtpub_u=${_wtpub_u#*://}            # 去掉 scheme
                _wtpub_u=${_wtpub_u#*@}              # 去掉 user@
                _wtpub_u=${_wtpub_u#*/} ;;           # 去掉 host:port/
        *@*:*)  _wtpub_u=${_wtpub_u#*@}              # git@github.com:o/r
                _wtpub_u=${_wtpub_u#*:} ;;
    esac
    _wtpub_u=${_wtpub_u#/}
    case "$_wtpub_u" in
        */*/*) return 1 ;;               # 多于两段，不认识
        */*)   printf '%s\n' "$_wtpub_u" ;;
        *)     return 1 ;;
    esac
}

# 本地记录的 tag 模板 → 实际 tag（strftime）
wt_publish_tag() {
    _wtpub_tpl=$1
    [ -n "$_wtpub_tpl" ] || _wtpub_tpl='snapshot-%Y-%m-%d'
    date +"$_wtpub_tpl"
}

# 有没有权限往这个仓推 release。第三方上游仓（neovim/neovim）会在这里被挡下。
wt_publish_can_push() {
    _wtpub_repo=$1
    if ! command -v gh >/dev/null 2>&1; then
        return 2                          # 没有 gh，调用方决定怎么办
    fi
    _wtpub_perm=$(gh repo view "$_wtpub_repo" --json viewerPermission -q .viewerPermission 2>/dev/null) || return 3
    case "$_wtpub_perm" in
        ADMIN|MAINTAIN|WRITE|PUSH) return 0 ;;
        *) printf '%s\n' "$_wtpub_perm"; return 1 ;;
    esac
}

# 打源码包：wt_pack_source <项目绝对路径> <输出文件> [额外目录 额外相对路径]
# 给了额外参数就再往里塞一个成员（用来放 .wtool-dist/<id>.json 标记）。
# 本机可用的打包压缩扩展名（没有 zstd 就 gz）。调用方据此决定资产名，
# 保证"文件名里的扩展名"和"包里的实际内容"永远一致。
wt_pack_ext() {
    if command -v zstd >/dev/null 2>&1; then printf 'zst'
    elif command -v gzip >/dev/null 2>&1; then printf 'gz'
    else printf 'tar'
    fi
}

# 打源码包：wt_pack_source <项目绝对路径> <输出文件> [额外目录 额外相对路径]
# 给了额外参数就再往里塞一个成员（用来放 .wtool-dist/<id>.json 标记）。
# 输出文件必须以 .tar.zst / .tar.gz / .tar 结尾，压缩器按扩展名选——
# 绝不出现"名字叫 zst、内容其实是 gz"这种事。
wt_pack_source() {
    _wtpub_proj=$1; _wtpub_out=$2; _wtpub_extra_dir=${3:-}; _wtpub_extra_rel=${4:-}
    _wtpub_prefix=${WTOOL_PUBLISH_PREFIX:-wtool}
    _wtpub_rel=$(python3 -c 'import os,sys;print(os.path.relpath(os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])))' \
               "$_wtpub_proj" "$WTOOL_ROOT") || wt_die "算不出 $_wtpub_proj 相对 $WTOOL_ROOT 的路径"
    case "$_wtpub_rel" in
        ..|../*|/*) wt_die "$_wtpub_proj 不在工作区 $WTOOL_ROOT 里，无法按 wtool/ 前缀打包" ;;
    esac
    [ -d "$WTOOL_ROOT/$_wtpub_rel" ] || wt_die "项目目录不存在: $WTOOL_ROOT/$_wtpub_rel"

    # 有 .git 就用 HEAD 提交时间当 mtime，打出来的包可复现（同样的树 → 同样的字节）
    _wtpub_mtime=""
    if git -C "$_wtpub_proj" rev-parse --git-dir >/dev/null 2>&1; then
        _wtpub_epoch=$(git -C "$_wtpub_proj" log -1 --format=%ct 2>/dev/null || true)
        [ -n "$_wtpub_epoch" ] && _wtpub_mtime="--mtime=@$_wtpub_epoch"
    fi

    wt_ensure_dir "$(dirname -- "$_wtpub_out")"
    if wt_dry; then
        wt_step "[dry-run] 打包 $_wtpub_rel → $_wtpub_out（前缀 $_wtpub_prefix/）"
        return 0
    fi

    _wtpub_tar="$_wtpub_out.tmp.$$.tar"
    # --transform 结尾那个 S 不能少：默认情况下 GNU tar 会把变换同时应用到
    # **符号链接的指向**上，于是包里的相对软链会被改写成
    #   themes/foo.zsh-theme -> wtool/bar.zsh-theme
    # 解压出来全是断链。S = 不要动符号链接的指向。
    # （实测 oh-my-zsh 的 themes/*.zsh-theme 和 plugins/*/*.plugin.zsh 中招。）
    # shellcheck disable=SC2086
    tar -C "$WTOOL_ROOT" \
        --transform="s|^|$_wtpub_prefix/|S" \
        --sort=name --numeric-owner --owner=0 --group=0 $_wtpub_mtime \
        --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' --exclude='*.pyo' \
        --exclude='.mypy_cache' --exclude='.pytest_cache' --exclude='.ruff_cache' \
        --exclude='*.log' \
        -cf "$_wtpub_tar" "$_wtpub_rel" || { rm -f "$_wtpub_tar"; wt_die "tar 打包失败: $_wtpub_rel"; }

    if [ -n "$_wtpub_extra_dir" ] && [ -n "$_wtpub_extra_rel" ]; then
        tar -C "$_wtpub_extra_dir" --transform="s|^|$_wtpub_prefix/|S" \
            --sort=name --numeric-owner --owner=0 --group=0 \
            -rf "$_wtpub_tar" "$_wtpub_extra_rel" \
            || { rm -f "$_wtpub_tar"; wt_die "追加 $_wtpub_extra_rel 失败"; }
    fi

    # 压缩器按输出扩展名选。名字和内容必须一致：用户拿到 .tar.zst 就该能
    # tar --zstd 解开，静默退化成 gzip 会让人以为包坏了。
    case "$_wtpub_out" in
        *.tar.zst) command -v zstd >/dev/null 2>&1 \
                       || wt_die "输出名是 .tar.zst 但本机没有 zstd（装 zstd，或用 wt_pack_ext 取扩展名）"
                   zstd -q -T0 -12 -f -o "$_wtpub_out" "$_wtpub_tar" \
                       || { rm -f "$_wtpub_tar"; wt_die "zstd 压缩失败"; } ;;
        *.tar.gz)  gzip -9 -c "$_wtpub_tar" > "$_wtpub_out" \
                       || { rm -f "$_wtpub_tar"; wt_die "gzip 压缩失败"; } ;;
        *.tar)     mv -f "$_wtpub_tar" "$_wtpub_out" ;;
        *) wt_die "输出名必须以 .tar.zst / .tar.gz / .tar 结尾，实际: $_wtpub_out" ;;
    esac
    rm -f "$_wtpub_tar"
    [ -s "$_wtpub_out" ] || wt_die "打出来的包是空的: $_wtpub_out"
    wt_step "打包 $(wc -c < "$_wtpub_out" | tr -d ' ') 字节 → $(basename -- "$_wtpub_out")"
}

# 建 release（已存在就复用）
wt_publish_gh_release() {
    _wtpub_repo=$1; _wtpub_tag=$2; _wtpub_title=$3; _wtpub_notes=$4
    if wt_dry; then
        wt_step "[dry-run] gh release create $_wtpub_tag --repo $_wtpub_repo"
        return 0
    fi
    if gh release view "$_wtpub_tag" --repo "$_wtpub_repo" >/dev/null 2>&1; then
        wt_step "release $_wtpub_tag 已存在，复用"
        return 0
    fi

    # view 失败不等于"不存在"：网络抖一下、或者 API 最终一致性，都会让 view
    # 报错。所以 create 失败之后要再判断一次，否则一个早就建好的 release
    # 会让整个 publish 硬失败（实测在 shell/zsh 上撞过 422 already exists）。
    _wtpub_err=$(mktemp "${TMPDIR:-/tmp}/wtool-gh.XXXXXX")
    if gh release create "$_wtpub_tag" --repo "$_wtpub_repo" \
            --title "$_wtpub_title" --notes "$_wtpub_notes" 2>"$_wtpub_err"; then
        wt_step "创建 release $_wtpub_tag @ $_wtpub_repo"
        rm -f -- "$_wtpub_err"
        return 0
    fi

    # 两重判断，因为这两种失败模式完全不同：
    #   1) create 自己说了"已存在" —— 确定性的，直接信它
    #   2) create 因为别的原因失败，而 view 现在能通了 —— 说明刚才是 view 抖了
    # 只做第 2 重是不够的：view 要是持续故障，就永远区分不出来。
    if grep -qiE 'already[ _-]?exists|tag_name already' "$_wtpub_err" 2>/dev/null; then
        wt_step "release $_wtpub_tag 已经存在（create 这么说的），复用"
        rm -f -- "$_wtpub_err"
        return 0
    fi
    if gh release view "$_wtpub_tag" --repo "$_wtpub_repo" >/dev/null 2>&1; then
        wt_step "release $_wtpub_tag 已经存在（view 现在能看到了），复用"
        rm -f -- "$_wtpub_err"
        return 0
    fi

    cat -- "$_wtpub_err" >&2
    rm -f -- "$_wtpub_err"
    wt_die "创建 release 失败: $_wtpub_repo $_wtpub_tag"
}

# 上传资产（可重复执行，--clobber 覆盖同名）
wt_publish_gh_upload() {
    _wtpub_repo=$1; _wtpub_tag=$2; shift 2
    [ "$#" -gt 0 ] || return 0
    if wt_dry; then
        wt_step "[dry-run] gh release upload $_wtpub_tag --repo $_wtpub_repo <$# 个文件>"
        return 0
    fi
    gh release upload "$_wtpub_tag" --repo "$_wtpub_repo" --clobber "$@" \
        || wt_die "上传失败: $_wtpub_repo $_wtpub_tag"
    wt_step "上传 $# 个文件 → $_wtpub_repo $_wtpub_tag"
}

# 记录本地发布历史（表格里的 publish 列离线也看得到）
#
# 记账失败绝不能影响发布：release 已经传上去了，丢一条本地历史是小事；
# 因为状态目录写不进去就报"发布失败"才是大事（用户会以为没发出去）。
wt_publish_record() {
    _wtpub_id=$1; _wtpub_repo=$2; _wtpub_tag=$3; _wtpub_n=$4; _wtpub_detail=$5
    [ -n "$_wtpub_id" ] || return 0
    wt_dry && return 0
    # 直接 mkdir 而不是 wt_ensure_dir：这是记账数据，不该进 journal
    if ! mkdir -p -- "$WTOOL_STATE/$_wtpub_id" 2>/dev/null; then
        wt_warn "记不了本地发布历史（$WTOOL_STATE 写不进去）：$_wtpub_repo $_wtpub_tag"
        wt_warn "发布本身已经完成，只是表格里的 publish 列看不到这一条"
        return 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        "$_wtpub_repo" "$_wtpub_tag" "$_wtpub_n" "$_wtpub_detail" \
        >> "$WTOOL_STATE/$_wtpub_id/publish.tsv" 2>/dev/null \
        || wt_warn "写 publish.tsv 失败（不影响发布）"
}


# --------------------------------------------------------------------------
# 动作记录：这个项目上执行过哪些动作
#
# 表格里那三列的"做没做过"就靠它。跟 journal 分开：
#   journal      "当前该撤销什么"，uninstall 逆着做，重复执行只更新
#   actions.tsv  "做过什么"的时间线，只追加，不参与回滚
# 两件事混在一张表里，迟早会互相污染。
# --------------------------------------------------------------------------
wt_record_action() {   # <项目 id> <动作名> [说明]
    _ra_id=$1; _ra_act=$2; _ra_note=${3:-}
    [ -n "$_ra_id" ] || return 0
    wt_dry && return 0
    mkdir -p -- "$WTOOL_STATE/$_ra_id" 2>/dev/null || return 0
    printf '%s\t%s\t%s\n' "$_ra_act" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$_ra_note" \
        >> "$WTOOL_STATE/$_ra_id/actions.tsv" 2>/dev/null || true
}

# 最近一次动作的时间戳（没有就打印空）
wt_last_action() {   # <项目 id> <动作名>
    _la_f="$WTOOL_STATE/$1/actions.tsv"
    [ -f "$_la_f" ] || return 0
    awk -F'\t' -v a="$2" '$1 == a {t = $2} END {if (t) print t}' "$_la_f"
}

wt_has_action() {   # <项目 id> <动作名>
    [ -n "$(wt_last_action "$1" "$2")" ]
}


# --------------------------------------------------------------------------
# 环境变量汇总：每次 install/uninstall 之后重新生成
#
# 顺序很重要 —— 先让项目的 env 块落盘（wt_plan_exec 干的），
# 再从这里把它们拼成 ~/.wtool/.zshrc，最后保证用户 rc 里只有一个 loader 块。
#
# 这一步是**全量重算**，不是增量修改。所以：
#   * 重复 install 不会堆积
#   * 删掉某个项目的块文件，它就自然从汇总里消失，不需要额外的"删除"逻辑
#   * 早期版本散在用户 rc 里的 per-project 块，会在这里被自动清掉（迁移）
# --------------------------------------------------------------------------
wt_env_sync() {
    wt_dry && return 0
    _es_scratch=$(mktemp -d "${TMPDIR:-/tmp}/wtool-env.XXXXXX") || return 0
    if ! python3 "$PY" plan-env --home "$WTOOL_HOME" --state "$WTOOL_STATE" \
            --scratch "$_es_scratch" >/dev/null 2>&1; then
        rm -rf -- "$_es_scratch"
        wt_warn "环境变量汇总失败，跳过（rc 里的块可能不同步）"
        return 0
    fi
    wt_plan_exec "$_es_scratch/plan.tsv"
    rm -rf -- "$_es_scratch"
}
