#!/bin/sh
# wtool 执行层 —— **受管**写入（软链 / rc 块 / journal / registry / 系统文件）都走这里。
#
# 契约（见 docs/spec.md §3）：
#   * 这些受管动作都经过本文件的函数（别处直接写 $HOME 的都不是受管动作，
#     例如 wtool.sh:631-633 往 $WTOOL_STATE/<id>/meta.tsv 追加记账行）
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

# 忘掉一条账（--prune 删掉软链之后用）：journal 描述的是"当前该撤销什么"，
# 东西已经主动撤了，这条就该消失 —— 留着它下次 --prune 还会再删一遍（无害但会撒谎）。
wt_journal_del() {   # <action> <dest>
    wt_dry && return 0
    [ -n "${WTOOL_JOURNAL:-}" ] || return 0
    [ -f "$WTOOL_JOURNAL" ] || return 0
    _jd_a=$1; _jd_d=$2
    _jd_tmp="$WTOOL_JOURNAL.tmp.$$"
    awk -F'\t' -v a="$_jd_a" -v d="$_jd_d" '!($1 == a && $3 == d)' \
        "$WTOOL_JOURNAL" > "$_jd_tmp" && mv -f -- "$_jd_tmp" "$WTOOL_JOURNAL"
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
    # 登记：这是 wtool 写的，不是用户手改的。
    # 唯一写文件入口就在这里，所以登记一次就够，不用每个调用点都记。
    wt_generated_add "$_real"
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
                wt_registry_set "$_dest" "${WTOOL_PROJECT_ID:--}" "$_kind"
                ;;
            link)
                wt_link_create "$_dest" "$_source"
                wt_registry_set "$_dest" "${WTOOL_PROJECT_ID:--}" "$_kind"
                ;;
            regdel)
                # 只清登记，不动磁盘（引擎自己造的东西收尾时用，如 ~/usr）
                wt_registry_del "$_dest"
                ;;
            unlink)
                # 引擎自己造的全局软链的收尾（~/usr）：只删**还指向原位**的那条，
                # 实体一个字节都不动
                if [ -L "$_dest" ] && { [ "$_source" = "-" ] \
                     || [ "$(readlink -- "$_dest")" = "$_source" ]; }; then
                    wt_run rm -f -- "$_dest"
                    wt_registry_del "$_dest"
                fi
                ;;
            prune)
                # `install --prune`（BL-15）：删掉"清单里已经删掉、磁盘上还在"的软链。
                # 和 unlink 的区别：这条是 journal 里的旧账，删完要**把账也销掉**。
                # 三道验：还是软链、还指向当初那个目标、账上确实有它 —— 缺一条就不动。
                if [ -L "$_dest" ] \
                   && { [ "$_source" = "-" ] || [ "$(readlink -- "$_dest")" = "$_source" ]; } \
                   && wt_journal_owns link "$_dest"; then
                    wt_run rm -f -- "$_dest"
                    wt_registry_del "$_dest"
                    wt_journal_del link "$_dest"
                    wt_step "prune $_dest（清单里已经没有）"
                fi
                ;;
            prune-dir)
                # 顺带收走空目录。非空的**一律留着** —— 里面可能是用户自己的东西
                wt_remove_dir_if_empty "$_dest"
                wt_journal_del mkdir "$_dest"
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

# --------------------------------------------------------------------------
# 状态目录里的项目清单（给 `uninstall all` / `sudo-uninstall all` 用）
#
# 判据是文件而不是 registry：registry 只记软链，一个"只有 env 块、没有软链"
# 的项目在它里面是空的；而从发布包解压出来的工作区可能连项目目录都没有了，
# 只能靠 state 里剩下的账认得出来。
# --------------------------------------------------------------------------
wt_installed_ids() {   # 装过的（有 meta.tsv 或 journal.tsv）
    [ -d "$WTOOL_STATE" ] || return 0
    find "$WTOOL_STATE" -type f \( -name meta.tsv -o -name journal.tsv \) \
        2>/dev/null | while IFS= read -r _ii_f; do
        _ii_d=$(dirname -- "$_ii_f")
        printf '%s\n' "${_ii_d#"$WTOOL_STATE"/}"
    done | LC_ALL=C sort -u
}

wt_sudo_ids() {   # 跑过系统层的（有 system.tsv / apt.tsv / provisioned/ / system/）
    [ -d "$WTOOL_STATE" ] || return 0
    find "$WTOOL_STATE" \( -name system.tsv -o -name apt.tsv -o -name provisioned \
         -o -name system \) 2>/dev/null | while IFS= read -r _si_p; do
        case $_si_p in
            *.tsv) _si_d=$(dirname -- "$_si_p") ;;
            *)     _si_d=$(dirname -- "$_si_p") ;;
        esac
        printf '%s\n' "${_si_d#"$WTOOL_STATE"/}"
    done | LC_ALL=C sort -u
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

# /etc 的改动**备份三份**（§3.3，冗余防不同场景的丢失）：
#   1 原文件旁边：/etc/apt/sources.list.d/ubuntu.sources.wtool-orig
#   2 /var/backups/wtool/<原始路径>        ← 要 root，非 root 时跳过并说明
#   3 $WTOOL_STATE/<id>/system/<slug>/original
# 三份各记 sha256，读取按 1→2→3 取第一份**校验通过**的；不一致要报出来，
# 不许默默挑一份用。
wt_sysfile_backups() {   # <dest> → 三份备份路径，按读取优先级
    printf '%s.wtool-orig\n' "$1"
    printf '/var/backups/wtool%s\n' "$1"
    printf '%s\n' "$WTOOL_STATE/${WTOOL_PROJECT_ID:-_}/system/$(wt_sysfile_slug "$1")/original"
}

# 系统层的账单独记一份（system.tsv），**不跟 install 的 journal 混**：
#   `wtool uninstall` 只删 install 的账（meta/journal/env），系统层的账留着，
#   `wtool sudo-uninstall` 才有依据还原（两层永不互相调用，见 §0）。
# 格式: mode \t dest \t 原始 sha256 \t 我们写的 sha256 \t desc
wt_sysfile_record_add() {   # <mode> <dest> <orig_sha> <new_sha> <desc>
    wt_dry && return 0
    [ -n "${WTOOL_PROJECT_ID:-}" ] || return 0
    _sr_dir="$WTOOL_STATE/$WTOOL_PROJECT_ID"
    mkdir -p -- "$_sr_dir" 2>/dev/null || return 0
    _sr_f="$_sr_dir/system.tsv"
    if [ -f "$_sr_f" ]; then
        awk -F'\t' -v d="$2" '$2 != d' "$_sr_f" > "$_sr_f.tmp.$$" \
            && mv -f -- "$_sr_f.tmp.$$" "$_sr_f"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$_sr_f"
}

# 写系统文件：备份（三份）→ 写入 → 记账
wt_sysfile_apply() {
    _mode=$1; _dest=$2; _content=$3; _sha=$4; _backup=$5; _desc=$6
    _slug=$(wt_sysfile_slug "$_dest")
    _b3="$WTOOL_STATE/$WTOOL_PROJECT_ID/system/$_slug/original"

    # dedup：清掉**我们自己**生成的重复镜像源。
    #
    # 场景（2026-10-04 实测）：install.sh 第 0 步已经按用户挑的镜像配好了一份
    # （/etc/apt/sources.list.d/wtool-mirror.sources），而项目清单里的
    # <sudo-install kind="apt-mirror" mirror="auto"/> 以前会再写一份 ubuntu.sources
    # —— 同一批 target 配两遍，apt 警告 "configured multiple times"，ansible 的
    # 装包任务会因此失败。现在 planner 认出"已经换过"就发这条 dedup，不再写第二份。
    #
    # 只删 head 里有"由 wtool 生成"的那种：机器**原来的**文件一个字节都不动。
    # 不记账（不进 system.tsv）：它本来就是我们生成的临时产物，还原它没有意义。
    if [ "$_mode" = dedup ]; then
        if [ -f "$_dest" ] && head -1 -- "$_dest" 2>/dev/null | grep -q '由 wtool 生成'; then
            wt_run rm -f -- "$_dest"
            wt_info "  已清掉重复的镜像源: $_dest（install.sh 那份才是当前的）"
        fi
        return 0
    fi

    if [ "$_mode" = disable ]; then
        if [ ! -e "$_dest" ]; then
            wt_warn "disable 的目标不存在，跳过: $_dest"
            return 0
        fi
        wt_run wt_sysfile_run "$_dest" mv -- "$_dest" "$_dest.wtool-disabled"
        wt_journal_add sysfile disable "$_dest" "$_dest.wtool-disabled" "-"
        wt_sysfile_record_add disable "$_dest" "-" "-" "$_desc"
        return 0
    fi

    _orig_sha=""
    if [ -e "$_dest" ]; then
        _orig_sha=$(wt_sha256 "$_dest")
    fi
    if [ "$_backup" = yes ] && [ -e "$_dest" ]; then
        if wt_dry; then
            wt_step "[dry-run] 备份 $_dest（原文件旁边 / var-backups / state 三份）"
        else
            _bak_ok=""
            # 第 3 份一定写得了（state 是我们的地盘）
            wt_ensure_dir "$(dirname -- "$_b3")"
            if wt_sysfile_run "$_dest" cp -f -- "$_dest" "$_b3" 2>/dev/null; then
                _bak_ok="$_bak_ok state"
            fi
            # 第 1 份：原文件旁边（直写得了就写，写不了不勉强）
            if wt_can_write "$_dest" && cp -f -- "$_dest" "$_dest.wtool-orig" 2>/dev/null; then
                _bak_ok="$_bak_ok orig"
            fi
            # 第 2 份：/var/backups（**要 root**）。非 root 直接说明跳过，
            # 不去碰 sudo —— 一个"顺手 sudo"的备份动作会变成密码提示。
            if [ "$(id -u)" = 0 ]; then
                mkdir -p -- "$(dirname -- "/var/backups/wtool$_dest")" 2>/dev/null \
                    && cp -f -- "$_dest" "/var/backups/wtool$_dest" 2>/dev/null \
                    && _bak_ok="$_bak_ok backups"
            fi
            wt_info "  备份:${_bak_ok:- 无}"
            case $_bak_ok in
                *backups*) ;;
                *) wt_info "  （/var/backups 那一份要 root，这次跳过 —— 其余两份照常）" ;;
            esac
        fi
    elif [ "$_mode" = add ] && [ -e "$_dest" ]; then
        wt_die "dest 已存在，且这条规则 backup=no / mode=add: $_dest"
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
    # journal 那一行留着做审计（§3.3：以后要审计靠 journal），
    # 但还原的**依据**是 system.tsv —— 它不会被 uninstall 删掉。
    wt_journal_add sysfile "$_mode" "$_dest" "$_b3" "$_sha"
    wt_sysfile_record_add "$_mode" "$_dest" "${_orig_sha:--}" "$_sha" "$_desc"
}

# 还原系统文件（sudo-uninstall 时由 system.tsv 触发）
wt_sysfile_restore() {   # <mode> <dest> <orig_sha> <new_sha>
    _mode=$1; _dest=$2; _orig_sha=$3; _new_sha=$4

    if [ "$_mode" = disable ]; then
        if [ -e "$_dest.wtool-disabled" ] && [ ! -e "$_dest" ]; then
            wt_run wt_sysfile_run "$_dest" mv -- "$_dest.wtool-disabled" "$_dest"
        fi
        return 0
    fi

    _pick=""; _pick_sha=""
    for _c in $(wt_sysfile_backups "$_dest"); do
        [ -f "$_c" ] || continue
        _cs=$(wt_sha256 "$_c")
        if [ -z "$_pick" ]; then
            _pick=$_c; _pick_sha=$_cs
        fi
        if [ -n "$_orig_sha" ] && [ "$_orig_sha" != "-" ] && [ "$_cs" = "$_orig_sha" ]; then
            _pick=$_c; _pick_sha=$_cs
            break
        fi
    done

    if [ -n "$_pick" ]; then
        if [ -n "$_orig_sha" ] && [ "$_orig_sha" != "-" ] && [ "$_pick_sha" != "$_orig_sha" ] \
           && [ "${WTOOL_FORCE:-0}" != 1 ]; then
            # 三份备份里没有一份和记录对得上 —— 报出来，不许默默挑一份用
            wt_die "备份内容和记录对不上: $_dest
  记录 sha256: $_orig_sha
  找到的备份: $_pick（$_pick_sha）
三份备份：$(wt_sysfile_backups "$_dest" | tr '\n' ' ')
确认要用它还原就加 --force。"
        fi
        if wt_dry; then
            wt_step "[dry-run] 还原 $_dest（来源 $_pick）"
        else
            _tmp="$_dest.wtool.restore.$$"
            wt_sysfile_run "$_dest" cp -f -- "$_pick" "$_tmp" || wt_die "还原失败: $_dest"
            wt_sysfile_run "$_dest" mv -f -- "$_tmp" "$_dest"
        fi
    elif [ -f "$_dest" ]; then
        _cur=$(wt_sha256 "$_dest")
        if [ "$_cur" = "$_new_sha" ] || [ "${WTOOL_FORCE:-0}" = 1 ]; then
            wt_run wt_sysfile_run "$_dest" rm -f -- "$_dest"
        else
            wt_warn "跳过（文件内容已被改动）: $_dest"
        fi
    fi

    # 三份全删：价值已经兑现（以后要审计靠 journal 里的文本记录）
    for _c in $(wt_sysfile_backups "$_dest"); do
        [ -e "$_c" ] || continue
        case $_c in
            /var/backups/*) [ "$(id -u)" = 0 ] && rm -f -- "$_c" 2>/dev/null || true ;;
            *) rm -f -- "$_c" 2>/dev/null || true ;;
        esac
    done
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
# 跑之前先把"这一步要装什么"说清楚（用户 2026-10-04 要求）。
#
# 背景：ansible 默认只在每个 task 开头打一行 `TASK [1/7 基础工具]`，
# 中间那几分钟（下载 + dpkg）完全看不到东西 —— 用户的原话是"只能感受到等待"。
# 这里补三件：包的数量、模拟出来的下载量、以及跑完之后"新装了几个"（进 apt.tsv 时也打）。
wt_task_plan_report() {   # <playbook 路径>
    _tp_src=$1
    _tp_pkgs=$(python3 "$PY" provision-packages "$_tp_src" 2>/dev/null || true)
    _tp_n=$(printf '%s\n' "$_tp_pkgs" | grep -c . 2>/dev/null || echo 0)
    [ "${_tp_n:-0}" -gt 0 ] || return 0
    _tp_tasks=$(grep -cE '^[[:space:]]+- name:' "$_tp_src" 2>/dev/null || echo "?")
    # `-s` 是 simulate：只问 apt"会装几个、升级几个"，不装不写（不需要 root）
    _tp_sim=$(LC_ALL=C apt-get -s install $_tp_pkgs 2>/dev/null \
              | sed -n 's/^\([0-9][0-9]* upgraded.*\)$/\1/p' | head -1)
    _tp_new=$(printf '%s' "$_tp_sim" | sed -n 's/.*, \([0-9][0-9]*\) newly installed.*/\1/p')
    _tp_upg=$(printf '%s' "$_tp_sim" | sed -n 's/^\([0-9][0-9]*\) upgraded.*/\1/p')
    if [ -n "$_tp_new" ] || [ -n "$_tp_upg" ]; then
        wt_info "  这一步：${_tp_n} 个包、${_tp_tasks} 个 task（apt 说：新装 ${_tp_new:-?}、升级 ${_tp_upg:-?}）"
    else
        wt_info "  这一步：${_tp_n} 个包、${_tp_tasks} 个 task"
    fi
    # 要下多少：`--print-uris` 把每个包的 URL 和大小打出来，加一下就是下载量。
    # 只读（--print-uris 不下载）。取不到就少说一句 —— 宁可不说，不要瞎报数字。
    # 注意两个坑（都踩过）：`split(x, a, " ")` 里**单个空格**是"按空白切、去掉首尾"，
    # 所以 a[1] 是文件名、a[2] 才是字节数（不是 a[3]，那是 MD5Sum）；
    # 行首那个单引号也别用 `.` 去配（`^.http` 能歪打正着，读的人却以为配的是 h）。
    _tp_sum=$(LC_ALL=C apt-get --print-uris -y install $_tp_pkgs 2>/dev/null \
              | awk -F"'" 'index($0, "http") == 2 {split($3, a, " "); s += a[2]; n++}
                           END {if (n) printf "%.1f MB（%d 个文件）", s/1048576, n}')
    [ -n "$_tp_sum" ] && wt_info "  要下载：$_tp_sum"
}

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
        export WTOOL_PROJECT_ID WTOOL_PROJECT_ROOT
        # ⚠️ 这里必须**重新指向项目检出目录**：在 `wtool.sh` 的 sudo-install 路径上，
        #    `WTOOL_PROJECT_DIR` 指的是"这个项目的状态目录"（journal/meta/apt.tsv 那堆，
        #    （见 wt_load_project），而项目脚本（build.sh / install.sh / 任务脚本）
        #    一直把它理解成"项目目录"。同一个名字两种含义 = 脚本会静默写错地方
        #    （实测：验收脚本里的任务把 marker 写到了状态目录，检查却看项目目录）。
        #    状态目录改叫 WTOOL_PROJECT_STATE_DIR，名字说清自己是什么。
        export WTOOL_PROJECT_STATE_DIR="$WTOOL_PROJECT_DIR"
        export WTOOL_PROJECT_DIR="${WTOOL_PROJECT_ROOT:-$_cwd}"
        # 无人值守：debconf 的交互提问会把任务挂死（容器里没人回答）
        DEBIAN_FRONTEND=noninteractive
        export DEBIAN_FRONTEND
        export WTOOL_SOURCE_DIR="${WTOOL_SOURCE_DIR:-}"
        export WTOOL_SOURCE_REF="${WTOOL_SOURCE_REF:-}"
        cd "$_cwd" || exit 1
        case $_runner in
            ansible)
                if ! command -v ansible-playbook >/dev/null 2>&1; then
                    # 包名逐版本试，**不写死**。
                    # ansible-core 是 22.04 才有的包名；20.04 上只有 ansible，
                    # 写死 ansible-core 会让 focal 的用户拿到一句
                    # "Unable to locate package"，然后自己猜该装什么 ——
                    # 而这时候源已经配好了，我们自己试一遍就行。
                    # （`./install.sh` 里也做了同样的事，这里是没走 install.sh
                    #   直接跑 wtool bootstrap 时的兜底。）
                    _priv=$(wt_priv)
                    for _p in ansible-core ansible; do
                        DEBIAN_FRONTEND=noninteractive \
                            ${_priv}apt-get install -y -qq --no-install-recommends "$_p" \
                            >/dev/null 2>&1 || true
                        command -v ansible-playbook >/dev/null 2>&1 && break
                    done
                fi
                command -v ansible-playbook >/dev/null 2>&1 \
                    || wt_die "缺少 ansible-playbook，自动装也没成功。
请手动执行（包名逐版本不同，22.04+ 是 ansible-core，20.04 是 ansible）：
  $(wt_priv)apt-get install -y --no-install-recommends ansible-core
  $(wt_priv)apt-get install -y --no-install-recommends ansible"
                # profile_tasks：每个 task 跑完打一行耗时，最后给一张表 ——
                # "看得见进度"里最省事的那一半（另一半在 wt_task_plan_report）。
                #
                # ⚠️ 先确认它真的在：各发行版的 ansible 打包不一样，24.04 的
                # ansible-core 里**没有**这个插件，写死会得到一句
                # "[WARNING]: Skipping callback plugin 'profile_tasks', unable to load"
                # （实测）。有就用，没有就算了 —— 我们自己的"用时"那行是兜底。
                if [ -z "${ANSIBLE_CALLBACKS_ENABLED:-}" ]; then
                    _cb_dir=$(python3 -c 'import ansible.plugins.callback as c, os
print(os.path.dirname(c.__file__))' 2>/dev/null || true)
                    if [ -n "$_cb_dir" ] && [ -f "$_cb_dir/profile_tasks.py" ]; then
                        ANSIBLE_CALLBACKS_ENABLED=profile_tasks
                        export ANSIBLE_CALLBACKS_ENABLED
                    fi
                fi
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

# 建 release（已存在就复用）
wt_publish_gh_release() {
    _wtpub_repo=$1; _wtpub_tag=$2; _wtpub_title=$3; _wtpub_notes=$4
    if wt_dry; then
        wt_step "[dry-run] gh release create $_wtpub_tag --repo $_wtpub_repo"
        return 0
    fi
    if wt_gh release view "$_wtpub_tag" --repo "$_wtpub_repo" >/dev/null 2>&1; then
        wt_step "release $_wtpub_tag 已存在，复用"
        return 0
    fi

    # view 失败不等于"不存在"：网络抖一下、或者 API 最终一致性，都会让 view
    # 报错。所以 create 失败之后要再判断一次，否则一个早就建好的 release
    # 会让整个 publish 硬失败（实测在 shell/zsh 上撞过 422 already exists）。
    _wtpub_err=$(mktemp "${TMPDIR:-/tmp}/wtool-gh.XXXXXX")
    if wt_gh release create "$_wtpub_tag" --repo "$_wtpub_repo" \
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
    if wt_gh release view "$_wtpub_tag" --repo "$_wtpub_repo" >/dev/null 2>&1; then
        wt_step "release $_wtpub_tag 已经存在（view 现在能看到了），复用"
        rm -f -- "$_wtpub_err"
        return 0
    fi

    cat -- "$_wtpub_err" >&2
    rm -f -- "$_wtpub_err"
    wt_die "创建 release 失败: $_wtpub_repo $_wtpub_tag"
}

# 上传资产（可重复执行，--clobber 覆盖同名）
# 选一条能通的到 GitHub 的路，整个发布都用它。
#
# 为什么要"选"而不是"试"：
# 代理出问题时**不一定立刻报错，可能是慢慢磨** —— 实测 314M 的分卷
# 磨了七分钟还没失败，等它失败才去试另一条路，白等的那七分钟纯属浪费。
# 一次探测只要一两秒，探完就不用赌了。
#
# 注意这是"选一条能通的路"，**不是"代理不能用"** ——
# 代理本身通常是好的（复测 api.github.com 200/1.1s），只是偶尔会抖。
#
# 探测用 gh api /rate_limit：它极轻（几百字节），又能真正验证
# 认证 + 连通性，比 ping 一个域名有意义。
wt_gh_route() {
    # 已经探过就直接复用（一次发布里会调很多次）
    if [ -n "${_WTOOL_GH_ROUTE:-}" ]; then
        printf '%s' "$_WTOOL_GH_ROUTE"; return 0
    fi
    _WTOOL_GH_ROUTE=current
    if [ -n "${HTTPS_PROXY:-}${https_proxy:-}${HTTP_PROXY:-}${http_proxy:-}" ]; then
        if ! timeout 20 gh api /rate_limit >/dev/null 2>&1; then
            if timeout 20 env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY \
                    -u http_proxy -u ALL_PROXY -u all_proxy \
                    gh api /rate_limit >/dev/null 2>&1; then
                wt_warn "代理连不上 GitHub，这次发布改用直连"
                _WTOOL_GH_ROUTE=direct
            fi
        fi
    fi
    printf '%s' "$_WTOOL_GH_ROUTE"
}

# 按选定的路执行 gh。$WTOOL_GH_ROUTE 为空/current 时用当前环境。
wt_gh() {
    case $(wt_gh_route) in
        direct) env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY \
                    -u http_proxy -u ALL_PROXY -u all_proxy gh "$@" ;;
        *)      gh "$@" ;;
    esac
}

wt_publish_gh_upload() {
    _wtpub_repo=$1; _wtpub_tag=$2; shift 2
    [ "$#" -gt 0 ] || return 0
    if wt_dry; then
        wt_step "[dry-run] gh release upload $_wtpub_tag --repo $_wtpub_repo <$# 个文件>"
        return 0
    fi
    # 这里**不能 die**。上传失败是可恢复的（代理抖一下就会 EOF），
    # 而一旦 die，cmd_publish 的 trap 会把刚花半小时构建出来的产物一起删掉，
    # 想重试就得从头再编。改成返回非零，让调用者决定：留住产物、报清楚、
    # 继续发下一个项目。
    # 实测：576M 的分卷传到一半 "Post ...: EOF"，整批产物被 trap 清空。
    if wt_gh release upload "$_wtpub_tag" --repo "$_wtpub_repo" --clobber "$@"; then
        wt_step "上传 $# 个文件 → $_wtpub_repo $_wtpub_tag"
        return 0
    fi

    # 走到这里说明探测选的路也不行了（网络中途变了）。换另一条再试一次。
    if [ "$(wt_gh_route)" = "current" ] \
       && [ -n "${HTTPS_PROXY:-}${https_proxy:-}${HTTP_PROXY:-}${http_proxy:-}" ]; then
        wt_warn "上传失败，绕开代理重试一次"
        _WTOOL_GH_ROUTE=direct
        if wt_gh release upload "$_wtpub_tag" --repo "$_wtpub_repo" --clobber "$@"; then
            wt_step "上传 $# 个文件 → $_wtpub_repo $_wtpub_tag（直连）"
            return 0
        fi
    fi

    wt_warn "上传失败: $_wtpub_repo $_wtpub_tag（$# 个文件）"
    wt_warn "  多半是网络/代理断了。产物已保留，可直接补传，不必重新构建。"
    return 1
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
            --exclude "${1:-}" --scratch "$_es_scratch" >/dev/null 2>&1; then
        rm -rf -- "$_es_scratch"
        wt_warn "环境变量汇总失败，跳过（rc 里的块可能不同步）"
        return 0
    fi
    wt_plan_exec "$_es_scratch/plan.tsv"
    rm -rf -- "$_es_scratch"
}


# --------------------------------------------------------------------------
# wtool 自己生成的文件
#
# 问题：publish 会改写受版本控制的文件（文档里的下载块、以后的 release.json）。
# 改完这些文件就"脏"了，**下一轮 publish 会以"有未提交改动"拒绝这个项目** ——
# 一次发布把下一次发布堵死。
#
# 做法：wtool 每次写文件都登记在册，脏检查时只豁免**它自己写过的那些**。
# 用户手改的内容照样算脏，不受影响。
#
# 为什么不用"特判某个文件名"：生成物会越来越多（release.json、
# pre_release.json、README 的下载块……），特判会一个个堆上去，
# 而且分不清"这是 wtool 写的"还是"用户改的"。
# --------------------------------------------------------------------------
wt_generated_add() {   # <绝对路径>
    wt_dry && return 0
    mkdir -p -- "$WTOOL_STATE" 2>/dev/null || return 0
    printf '%s\t%s\t%s\n' "$1" "${WTOOL_PROJECT_ID:--}" \
        "$(date +%Y-%m-%dT%H:%M:%S%z)" >> "$WTOOL_STATE/generated.tsv" 2>/dev/null || true
}

# 这个文件是 wtool 自己写的吗
wt_generated_owns() {   # <绝对路径>
    _go_f="$WTOOL_STATE/generated.tsv"
    [ -f "$_go_f" ] || return 1
    awk -F'\t' -v p="$1" '$1 == p { found = 1 } END { exit !found }' "$_go_f"
}

# 项目里"真正脏"的文件（扣掉 wtool 自己写过的那几个）
# 输出和 `git status --porcelain` 一样，没有输出就是干净
wt_git_dirty() {   # <项目目录>
    _gd_dir=$(cd -- "$1" && pwd)
    _gd_all=$(git -C "$_gd_dir" status --porcelain 2>/dev/null || true)
    [ -n "$_gd_all" ] || return 0
    printf '%s\n' "$_gd_all" | while IFS= read -r _gd_line; do
        [ -n "$_gd_line" ] || continue
        # porcelain 格式：XY<空格>路径（重命名是 "XY 旧 -> 新"）
        _gd_f=$(printf '%s' "$_gd_line" | cut -c4-)
        case $_gd_f in *' -> '*) _gd_f=${_gd_f##* -> } ;; esac
        _gd_abs="$_gd_dir/$_gd_f"
        # ⚠️ 未跟踪的**目录**会被 git 折叠成一行 `?? docs/`，而生成物登记表里
        # 记的是文件（`docs/download.md`）。不展开的话，`pack-release` 刚写的
        # `docs/download.md` 会让整个项目判成"脏"，**一次生成把下一次发布堵死**
        # —— 正是 generated.tsv 要解决的那个问题，只是折叠目录把它绕过去了。
        if [ -d "$_gd_abs" ]; then
            _gd_any=0
            while IFS= read -r _gd_sub; do
                [ -n "$_gd_sub" ] || continue
                wt_generated_owns "$_gd_dir/$_gd_sub" || _gd_any=1
            done <<EOF
$(git -C "$_gd_dir" ls-files --others --exclude-standard -- "$_gd_f" 2>/dev/null)
EOF
            [ "$_gd_any" = 1 ] && printf '%s\n' "$_gd_line"
            continue
        fi
        wt_generated_owns "$_gd_abs" || printf '%s\n' "$_gd_line"
    done
}


# ==========================================================================
# pack-release / unpack-release
#
# 分工：Python 只算"打哪些文件"（读 .gitignore 是文本逻辑，见 wtool_plan.py
# 的 pack-plan），切卷、算 sha256、落盘全在这里做。
#
# 归档用 lib/wtool_zip.py（python3 zipfile）而不是系统的 zip 命令：
# 这台机器上的 Info-ZIP **不设 UTF-8 名字标志**（实测 flag_bits=0），
# 而归档名里有中文（源码.zip / release.zip），用别的工具解开就是乱码。
# 它和 tar/gzip 一样只是个工具，由这一层调用、写调用方给的路径。
# ==========================================================================
WT_ZIP_TOOL="$here/lib/wtool_zip.py"

wt_sha256() { sha256sum -- "$1" | cut -d' ' -f1; }
wt_bytes()  { wc -c < "$1" | tr -d ' '; }

# "32M" / "128M" / "1G" / 字节数 → 字节数
wt_size_bytes() {
    case $1 in
        *[Kk]) printf '%s' $(( ${1%[Kk]} * 1024 )) ;;
        *[Mm]) printf '%s' $(( ${1%[Mm]} * 1048576 )) ;;
        *[Gg]) printf '%s' $(( ${1%[Gg]} * 1073741824 )) ;;
        *)     printf '%s' "$1" ;;
    esac
}

wt_hash_file() {   # <文件> → "sha256  名字"
    printf '%s  %s\n' "$(wt_sha256 "$1")" "$(basename -- "$1")"
}

# 生成 zip。dry-run 时只报数，不产文件。
# 多出来的参数原样转给 wtool_zip.py（--prefix= / --extra <abs> <arc>）。
wt_zip_create() {   # <out.zip> <base-dir> <list-file> [--prefix=P] [--extra ...]
    _zc_out=$1; _zc_base=$2; _zc_list=$3; shift 3
    _zc_n=$(awk 'END{print NR}' "$_zc_list" 2>/dev/null || echo 0)
    if wt_dry; then
        wt_step "[dry-run] 打包 $(basename -- "$_zc_out")（$_zc_n 个文件）"
        return 0
    fi
    python3 "$WT_ZIP_TOOL" create "$_zc_out" "$_zc_base" "$_zc_list" "$@" \
        || wt_die "打包失败: $_zc_out"
    wt_step "打包 $(basename -- "$_zc_out")（$_zc_n 个文件，$(wt_bytes "$_zc_out") 字节）"
}

# 解开一个包：zip 走 wtool_zip.py，tar.* 走 tar
wt_unpack_one() {   # <包文件> <目标目录>
    _uo_pkg=$1; _uo_dest=$2
    case $_uo_pkg in
        *.zip)  python3 "$WT_ZIP_TOOL" extract "$_uo_pkg" "$_uo_dest" \
                    || wt_die "解包失败: $_uo_pkg" ;;
        *.tar.zst) tar --zstd -xf "$_uo_pkg" -C "$_uo_dest" || wt_die "解包失败: $_uo_pkg" ;;
        *.tar.gz|*.tgz) tar -xzf "$_uo_pkg" -C "$_uo_dest" || wt_die "解包失败: $_uo_pkg" ;;
        *.tar)  tar -xf "$_uo_pkg" -C "$_uo_dest" || wt_die "解包失败: $_uo_pkg" ;;
        *)      wt_warn "不认识的包格式，原样留着: $_uo_pkg" ;;
    esac
}

# 打一个项目的发布包 → <项目>/release/
#   wt_pack_release <项目目录> <tag> <repo> <卷大小> <scratch> [<项目id>]
wt_pack_release() {
    _pk_dir=$1; _pk_tag=$2; _pk_repo=$3; _pk_vol=$4; _pk_scratch=$5; _pk_pid=${6:-}
    _pk_pub="$_pk_dir/release"

    # 1) 算文件表：源码包读 .gitignore（**必须**，否则 GB 级 output/ 会被打进去），
    #    release 包用 output/ 里的全部东西 + 声明面。
    python3 "$PY" pack-plan "$_pk_dir" --scratch "$_pk_scratch" \
        > "$_pk_scratch/pack.log" 2>&1 || {
        cat -- "$_pk_scratch/pack.log" >&2
        wt_die "算发布文件表失败: $_pk_dir"
    }
    _pk_declare=$(awk -F'\t' '{printf "%s%s", sep, $1; sep=","}' \
                  "$_pk_scratch/declare.tsv" 2>/dev/null || true)
    _pk_nsrc=$(awk 'END{print NR}' "$_pk_scratch/source.files" 2>/dev/null || echo 0)
    _pk_nrel=$(awk 'END{print NR}' "$_pk_scratch/release.files" 2>/dev/null || echo 0)

    if wt_dry; then
        wt_step "[dry-run] 源码.zip  ← $_pk_nsrc 个文件（已按 .gitignore 过滤，永远排除 output/ release/）"
        wt_step "[dry-run] release.zip ← $_pk_nrel 个文件 + 声明面 ${_pk_declare:-（无）}"
        wt_step "[dry-run] 写 $_pk_pub/：dist.json、源码-hash.txt、release-hash.txt、超 $_pk_vol 就切分卷"
        wt_step "[dry-run] 写 $_pk_dir/docs/download.md 和 $_pk_pub/.source（来源标记）"
        wt_step "[dry-run] 发布地址 https://github.com/$_pk_repo/releases/download/$_pk_tag/"
        return 0
    fi

    if [ "$_pk_nrel" -le 0 ]; then
        # 纯声明式项目（只有 wtool.xml + 配置，没有 build/download）本来就没有产物。
        # 有 build.sh 却拿不出 output/ 才是真错误 —— 那多半是忘了 build，
        # 发出去的会是半成品。
        if [ -f "$_pk_dir/scripts/build.sh" ] || [ -f "$_pk_dir/build.sh" ]; then
            wt_die "output/ 里什么都没有 —— 先跑 wtool build ${_pk_pid:-<项目>}（或者 wtool download-release + wtool unpack-release）"
        fi
        wt_info "没有 output/（这个项目没有产物）：release.zip 只带声明面"
    fi

    wt_run mkdir -p -- "$_pk_pub"
    # 只清掉"这次会重新生成"的文件。release/ 也可能是 unpack-release 的下载落点，
    # 把用户下下来的东西删了是最难解释的那种事故。
    rm -f -- "$_pk_pub/源码.zip" "$_pk_pub/release.zip" "$_pk_pub/dist.json" \
             "$_pk_pub/源码-hash.txt" "$_pk_pub/release-hash.txt" 2>/dev/null || true
    rm -f -- "$_pk_pub/源码.zip-vol"* "$_pk_pub/release.zip-vol"* 2>/dev/null || true

    # 2) 两个包
    #
    # 源码包：第一层是 wtool/（**固定名，跟本机工作区目录叫什么无关**），
    # 所以解压到工作区上一层得到的路径和 repo sync 完全一致；
    # 再带上 .wtool-dist/<id>.json 标记 —— 解压副本没有 .git，
    # 靠这个标记才认得出"这是 wtool 发布的副本"，head 也才有出处。
    _pk_commit=$(git -C "$_pk_dir" rev-parse HEAD 2>/dev/null || echo "")
    _pk_dirty=0
    [ -n "$(git -C "$_pk_dir" status --porcelain 2>/dev/null)" ] && _pk_dirty=1
    _pk_dashed=$(printf '%s' "$_pk_pid" | tr '/' '-')
    wt_run mkdir -p -- "$_pk_scratch/dist/.wtool-dist"
    cat > "$_pk_scratch/dist/.wtool-dist/$_pk_dashed.json" <<EOF
{
  "project": "$_pk_pid",
  "repo": "$_pk_repo",
  "commit": "$_pk_commit",
  "dirty": $([ "$_pk_dirty" = 1 ] && echo true || echo false),
  "packed_at": "$(wt_now)",
  "view": "release",
  "layout": "wtool/$_pk_pid"
}
EOF
    # 包内第一层 = wtool/<项目在工作区里的相对路径>，解压到工作区上一层
    # 得到的路径和 repo sync 完全一致（项目 id 和工作区路径大多相同，
    # 但 id 是对外契约、可以自己写，所以这里按**真实相对路径**算）。
    _pk_rel=$(python3 -c 'import os,sys
print(os.path.relpath(os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])))' \
              "$_pk_dir" "$WTOOL_ROOT" 2>/dev/null || echo "$_pk_pid")
    case $_pk_rel in ..|../*|/*) _pk_rel=$_pk_pid ;; esac

    if [ "$_pk_nsrc" -gt 0 ]; then
        wt_zip_create "$_pk_pub/源码.zip" "$_pk_dir" "$_pk_scratch/source.files" \
            --prefix="wtool/$_pk_rel/" \
            --extra "$_pk_scratch/dist/.wtool-dist/$_pk_dashed.json" \
                    "wtool/.wtool-dist/$_pk_dashed.json"
        wt_hash_file "$_pk_pub/源码.zip" > "$_pk_pub/源码-hash.txt"
    else
        wt_warn "源码包是空的（.gitignore 是否把什么都排除了？），跳过"
    fi

    : > "$_pk_scratch/release.all"
    cat -- "$_pk_scratch/release.files" >> "$_pk_scratch/release.all"
    cut -f2 "$_pk_scratch/declare.tsv" >> "$_pk_scratch/release.all" 2>/dev/null || true
    LC_ALL=C sort -u -o "$_pk_scratch/release.all" "$_pk_scratch/release.all"
    wt_zip_create "$_pk_pub/release.zip" "$_pk_dir" "$_pk_scratch/release.all"
    wt_hash_file "$_pk_pub/release.zip" > "$_pk_pub/release-hash.txt"

    # 3) 分卷（大包传不上去：实测直连 ~237KB/s，几分钟断一次）
    : > "$_pk_scratch/rows.tsv"
    _pk_volbytes=$(wt_size_bytes "$_pk_vol")
    for _pk_name in 源码.zip release.zip; do
        [ -f "$_pk_pub/$_pk_name" ] || continue
        _pk_b=$(wt_bytes "$_pk_pub/$_pk_name")
        case $_pk_name in
            源码.zip) _pk_role=source ;;
            *)        _pk_role=release ;;
        esac
        printf '%s\t%s\t%s\t%s\t\n' "$_pk_name" "$(wt_sha256 "$_pk_pub/$_pk_name")" \
            "$_pk_b" "$_pk_role" >> "$_pk_scratch/rows.tsv"
        if [ "$_pk_b" -gt "$_pk_volbytes" ]; then
            wt_info "  $_pk_name 有 $((_pk_b / 1048576))M，按 $_pk_vol 一卷切开"
            split -b "$_pk_vol" -d -a 2 --numeric-suffixes=1 \
                "$_pk_pub/$_pk_name" "$_pk_pub/$_pk_name-vol" || wt_die "切分卷失败: $_pk_name"
            # 大文件本身不留在 release/：它正是传不上去的那个。
            # （留在 scratch 里，调用方的临时目录一删就没了）
            mv -f -- "$_pk_pub/$_pk_name" "$_pk_scratch/$_pk_name"
            for _pk_v in "$_pk_pub/$_pk_name"-vol*; do
                printf '%s\t%s\t%s\tvolume\t%s\n' "$(basename -- "$_pk_v")" \
                    "$(wt_sha256 "$_pk_v")" "$(wt_bytes "$_pk_v")" "$_pk_name" \
                    >> "$_pk_scratch/rows.tsv"
            done
        fi
    done

    # 4) dist.json（每卷的名字 / sha256 / 大小，按顺序逐个声明）
    python3 "$PY" write-dist --out "$_pk_scratch/dist.json" --rows "$_pk_scratch/rows.tsv" \
        --project-id "$_pk_pid" --tag "$_pk_tag" --repo "$_pk_repo" \
        --commit "$(git -C "$_pk_dir" rev-parse HEAD 2>/dev/null || echo -)" \
        --at "$(wt_now)" --volume-size "$_pk_vol" --declare "$_pk_declare" \
        || wt_die "写 dist.json 失败"
    cp -f -- "$_pk_scratch/dist.json" "$_pk_pub/dist.json"

    # 5) 声明面：**来源标记** + 给人看的下载页
    #
    #    ⚠️ `scripts/downloads.sh` 删掉了（ADR-023/026）：那份"这次发了什么"的清单
    #    归 `scripts/release.json`，而它由 `publish-release` 在**上传成功之后**写
    #    （因为要等 base_url / published_at 定下来）。这里只放一个来源标记，
    #    让 publish-release 能拒绝"把刚下下来的包又传回去"。
    wt_run mkdir -p -- "$_pk_dir/scripts" "$_pk_dir/docs"
    # --release-dir：资产表按**目录里实际有的文件**渲染，和 scripts/release.json 的
    # assets[] 是同一批（页面漏一个，照页面手动下的人就缺一个 —— 测试盯着这条）。
    python3 "$PY" download-doc --rows "$_pk_scratch/rows.tsv" --release-dir "$_pk_pub" \
        --tag "$_pk_tag" --repo "$_pk_repo" --project-id "$_pk_pid" \
        --at "$(date +%Y-%m-%d)" \
        > "$_pk_scratch/download.md" || wt_die "生成 download.md 失败"
    cp -f -- "$_pk_scratch/download.md" "$_pk_dir/docs/download.md"
    wt_generated_add "$_pk_dir/docs/download.md"
    printf 'packed\t%s\t%s\t%s\t%s\n' "$_pk_repo" "$_pk_tag" \
        "$(git -C "$_pk_dir" rev-parse HEAD 2>/dev/null || echo -)" "$(wt_now)" \
        > "$_pk_pub/.source"

    _pk_n=$(awk -F'\t' '$4=="volume"{v++; next} {n++} END{printf "%d 个文件 / %d 个分卷", n, v}' \
            "$_pk_scratch/rows.tsv")
    wt_info "发布包已生成: $_pk_pub（$_pk_n）"
    wt_info "  下一步: wtool publish-release ${_pk_pid:-<项目>}   # 上传 + 写 scripts/release.json"
    wt_info "  该提交的（文本，进 Git）：docs/download.md 和上传后的 scripts/release.json"
    wt_info "  release/ 是待上传目录（.gitignore 里，不进 Git）"
}

# 按 dist.json 校验分卷 → 拼接 → 解开到 <项目>/output/ 和项目根
#   wt_unpack_release <项目目录> <scratch>
wt_unpack_release() {
    _ur_dir=$1; _ur_scratch=$2
    _ur_pub="$_ur_dir/release"
    _ur_dist="$_ur_pub/dist.json"
    [ -f "$_ur_dist" ] || wt_die "没有 $_ur_dist —— 把 dist.json 和所有分卷下到项目 release/ 里"

    python3 "$PY" read-dist "$_ur_dist" > "$_ur_scratch/dist.rows.tsv" \
        || wt_die "读不了 dist.json: $_ur_dist"
    _ur_rows="$_ur_scratch/dist.rows.tsv"
    _ur_legacy=$(awk -F'\t' '$1=="meta" && $2=="legacy"{print 1}' "$_ur_rows")
    _ur_tmp="$_ur_scratch/unpack"

    # 老格式（astronvim 自己的 publish.sh 写的那种：只有 volumes + compression，
    # 没有 files 段）**不再支持**（ADR-023：彻底抛弃历史代码）。
    # 明确报错，不做"猜着解一半"—— 那会留下一个看起来装好了、其实缺东西的 output/。
    if [ "$_ur_legacy" = 1 ]; then
        wt_die "$_ur_dist 是老格式（没有 files 段，只有 volumes + compression）——
  2026-09-28 起不再支持这种包（见 harness/docs/adr/0023）。
  两条路：①用当时的 wtool 版本解开它；②重发一版新包：wtool pack-release <项目>"
    fi

    _ur_field() {   # <kind> <name> <列号>
        awk -F'\t' -v k="$1" -v n="$2" -v c="$3" '$1==k && $2==n {print $c}' "$_ur_rows"
    }

    _ur_got=0
    for _ur_name in $(awk -F'\t' '$1=="file"{print $2}' "$_ur_rows"); do
        _ur_role=$(_ur_field file "$_ur_name" 5)
        _ur_sha=$(_ur_field file "$_ur_name" 3)
        _ur_vols=$(awk -F'\t' -v n="$_ur_name" '$1=="volume" && $5==n {print $2}' "$_ur_rows")
        if [ -n "$_ur_vols" ]; then
            # install 只消费 release.zip（§5）：源码包的分卷不全就跳过，
            # 不是错误 —— 只下 release.zip 的机器完全合法。
            _ur_lack=""
            for _ur_v in $_ur_vols; do
                [ -f "$_ur_pub/$_ur_v" ] || { _ur_lack=$_ur_v; break; }
            done
            if [ -n "$_ur_lack" ]; then
                if [ "$_ur_role" = "source" ]; then
                    wt_warn "源码包的分卷不全（缺 $_ur_lack），跳过 —— install 不需要它"
                    continue
                fi
                wt_die "缺分卷: $_ur_pub/$_ur_lack"
            fi
            wt_run mkdir -p -- "$_ur_tmp"
            _ur_out="$_ur_tmp/$_ur_name"
            : > "$_ur_out"
            _ur_k=0
            for _ur_v in $_ur_vols; do
                _ur_exp=$(_ur_field volume "$_ur_v" 3)
                _ur_have=$(wt_sha256 "$_ur_pub/$_ur_v")
                [ "$_ur_have" = "$_ur_exp" ] || wt_die "分卷校验失败: $_ur_v
  期望 sha256: $_ur_exp
  实际 sha256: $_ur_have"
                cat -- "$_ur_pub/$_ur_v" >> "$_ur_out"
                _ur_k=$((_ur_k + 1))
            done
            wt_step "拼接 $_ur_k 卷 → $_ur_name"
        else
            _ur_out="$_ur_pub/$_ur_name"
            if [ ! -f "$_ur_out" ]; then
                if [ "$_ur_role" = "source" ]; then
                    wt_warn "源码包没下，跳过（install 只认 release.zip）: $_ur_name"
                    continue
                fi
                wt_die "缺文件: $_ur_out（把 dist.json 和它一起下到 release/）"
            fi
        fi
        if [ -n "$_ur_sha" ] && [ "$_ur_sha" != "-" ]; then
            _ur_have=$(wt_sha256 "$_ur_out")
            [ "$_ur_have" = "$_ur_sha" ] || wt_die "$_ur_name 整体校验失败（下载不完整？）
  期望 sha256: $_ur_sha
  实际 sha256: $_ur_have"
        fi
        if [ "$_ur_role" = "source" ]; then
            # 源码包只校验不铺开：install 只消费 release.zip，装东西的人不需要源码
            wt_info "源码包校验通过（不铺开）: $_ur_name"
            _ur_got=$((_ur_got + 1))
            continue
        fi
        wt_info "解开 $_ur_name → $_ur_dir"
        wt_run mkdir -p -- "$_ur_dir"
        wt_unpack_one "$_ur_out" "$_ur_dir"
        _ur_got=$((_ur_got + 1))
    done


    [ "$_ur_got" -gt 0 ] || wt_die "dist.json 里没有可解的东西: $_ur_dist"
    wt_info "unpack-release 完成（只校验 + 铺到 output/，不做安装）"
    wt_info "  下一步: wtool install $_ur_dir"
}


# ==========================================================================
# sudo-install：apt 差集（装了哪些包）——只记"这次新装进来的"
#
# sudo-uninstall 要能把包卸掉，可是 playbook / 脚本里装了什么引擎读不出来。
# 做法：跑之前和跑之后各取一次已装包快照，差集就是这次的账。
# 只删这次的账 —— 用户本来就在的包一个都不碰。
# ==========================================================================
wt_apt_snapshot() {   # 打印已装包名（一行一个）；没有 dpkg 就返回 1
    command -v dpkg-query >/dev/null 2>&1 || return 1
    dpkg-query -W -f='${Package}\n' 2>/dev/null | LC_ALL=C sort
}

wt_apt_record_new() {   # <项目id> <before文件> <after文件>
    _ar_id=$1; _ar_before=$2; _ar_after=$3
    wt_dry && return 0
    [ -f "$_ar_before" ] && [ -f "$_ar_after" ] || return 0
    _ar_new=$(LC_ALL=C comm -13 -- "$_ar_before" "$_ar_after" 2>/dev/null | sed '/^$/d' || true)
    [ -n "$_ar_new" ] || return 0
    mkdir -p -- "$WTOOL_STATE/$_ar_id" 2>/dev/null || return 0
    printf '%s\n' "$_ar_new" | while IFS= read -r _ar_p; do
        [ -n "$_ar_p" ] || continue
        printf '%s\t%s\n' "$_ar_p" "$(date +%Y-%m-%dT%H:%M:%S%z)"
    done >> "$WTOOL_STATE/$_ar_id/apt.tsv" 2>/dev/null || true
    wt_info "记账：本次新装了 $(printf '%s\n' "$_ar_new" | awk 'END{print NR}') 个包（sudo-uninstall 会卸掉它们）"
    # 顺手把名字列出来（最多 12 个）：只说个数的话，用户还是不知道装了什么
    printf '%s\n' "$_ar_new" | head -12 | tr '\n' ' ' | sed 's/^/        /' >&2
    _ar_rest=$(printf '%s\n' "$_ar_new" | awk 'END{print NR-12}')
    [ "${_ar_rest:-0}" -gt 0 ] && printf '        …（还有 %s 个）\n' "$_ar_rest" >&2
    printf '\n' >&2
}

wt_apt_remove_recorded() {   # <项目id>
    _rr_id=$1
    _rr_f="$WTOOL_STATE/$_rr_id/apt.tsv"
    [ -s "$_rr_f" ] || return 0
    _rr_pkgs=$(awk -F'\t' '{print $1}' "$_rr_f" | LC_ALL=C sort -u | tr '\n' ' ')
    [ -n "$_rr_pkgs" ] || return 0
    # WTOOL_APT_GET 是给测试用的桩：真环境永远是 apt-get
    _rr_apt=${WTOOL_APT_GET:-apt-get}
    if ! command -v "$_rr_apt" >/dev/null 2>&1; then
        wt_warn "找不到 $_rr_apt，跳过 apt 卸载。这些包是 wtool 装进来的："
        wt_warn "  $_rr_pkgs"
        return 0
    fi
    wt_info "apt 卸载本次装进来的包: $_rr_pkgs"
    # shellcheck disable=SC2086
    wt_run wt_sysfile_run /etc "$_rr_apt" remove -y $_rr_pkgs \
        || wt_warn "apt 卸载没成功（包名可能在别的发行版上不存在），请手工检查"
}


# ==========================================================================
# kill-self-forever：删掉 wtool 的一切痕迹
#
# 分两类，界线**只有一条**：wtool 自己铺的（软链、~/.wtool、状态）删；
# 系统层（apt 包、/etc）不删 —— 那是 sudo-uninstall 的事（不越权）。
# ==========================================================================
wt_kill_links() {   # 从 stdin 读 kill-plan 的输出，只删"还指向原位"的软链
    while IFS='	' read -r _kl_kind _kl_dest _kl_target; do
        [ -n "${_kl_kind:-}" ] || continue
        case $_kl_kind in
            link)
                if [ -L "$_kl_dest" ]; then
                    if [ "$_kl_target" = "-" ] \
                       || [ "$(readlink -- "$_kl_dest")" = "$_kl_target" ]; then
                        wt_run rm -f -- "$_kl_dest"
                    else
                        wt_warn "跳过（指向已变，可能是你自己的链）: $_kl_dest"
                    fi
                fi
                ;;
        esac
    done
}

wt_kill_paths() {   # 从 stdin 读 kill-plan 的输出，删目录
    while IFS='	' read -r _kp_kind _kp_dest _kp_target; do
        [ -n "${_kp_kind:-}" ] || continue
        case $_kp_kind in
            dir)
                if [ -e "$_kp_dest" ]; then
                    wt_run rm -rf -- "$_kp_dest"
                fi
                ;;
        esac
    done
}
