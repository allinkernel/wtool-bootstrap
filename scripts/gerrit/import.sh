#!/bin/sh
# import.sh —— 把工作区里每个项目"原样"搬进 gerrit（建项目 + 推 main）
#
# 这是**导入既有历史**，不是提交改动：推的是各仓库当前的 HEAD
# （= GitHub 上那个 main），用的是 admin 身份，所以不需要 +2。
# 从这以后，任何新改动都必须走 refs/for/main。
#
#   sh import.sh                 # 缺什么补什么（幂等）
#   sh import.sh --dry-run       # 只说要做什么
#   sh import.sh --force         # 连已存在的分支也重推（历史被改过时才用）
#
# 跳过三类：
#   * 没有 .git 的（发布包解出来的工作区）
#   * shallow clone（git 不允许从浅克隆推）
#   * 上游镜像/fork（见 gerrit_skip_reason）：它们不在这套检视流程里，
#     而且历史里的老对象 JGit 可能不收
# 单个项目推失败不会中断整体：最后汇总，退出码非 0。
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
. "$here/lib.sh"

dry=0; force=0
for a in "$@"; do
    case $a in
        --dry-run) dry=1 ;;
        --force) force=1 ;;
        *) gerrit_die "不认识的参数: $a" ;;
    esac
done

root=$(gerrit_find_root "$here") || gerrit_die "往上找不到工作区根（没有 .repo）"
gerrit_require_docker
gerrit_wait_ready

work=$(mktemp -d "${TMPDIR:-/tmp}/wtool-gerrit-import.XXXXXX")
trap 'rm -rf -- "$work"' EXIT INT TERM

failed=0

# 为什么有的项目干脆不导入
gerrit_skip_reason () {   # <path> <name>
    case $1 in
        editor/astronvim_v5/nvim)
            printf '%s\n' "上游 neovim 镜像（浅克隆），不在这套检视流程里" ;;
        shell/oh-my-zsh)
            printf '%s\n' "上游 fork；它有老 tree 用了零填充 filemode（040000），JGit 直接拒收" ;;
        *)
            return 1 ;;
    esac
}

# 一次把项目列表抓下来，别每个项目问一次
gerrit_admin_ssh "$root" gerrit ls-projects </dev/null > "$work/projects" ||
    gerrit_die "拿不到项目列表"
gerrit_has_project () { grep -qx "$1" "$work/projects"; }

gerrit_has_branch () {   # <project> <branch>
    [ -f "$work/branches.$2" ] || \
        gerrit_admin_ssh "$root" gerrit ls-projects --show-branch "$2" </dev/null \
        | awk '{print $2}' > "$work/branches.$2"
    grep -qx "$1" "$work/branches.$2"
}

gerrit_import_one () {   # <dir> <project> <branch> <显示名> [从哪个目录推]
    dir=$1; gproject=$2; gbranch=$3; label=$4; pushdir=${5:-$1}
    if gerrit_has_project "$gproject"; then
        :
    elif [ "$dry" = 1 ]; then
        gerrit_info "[dry] create-project $gproject"
    else
        gerrit_info "==> create-project $gproject（parent=All-Projects）"
        gerrit_admin_ssh "$root" gerrit create-project --parent All-Projects \
            --owner Administrators --description "'wtool: $label'" "$gproject" >/dev/null
        printf '%s\n' "$gproject" >> "$work/projects"
    fi

    if [ "$force" = 0 ] && gerrit_has_branch "$gproject" "$gbranch"; then
        gerrit_info "跳过 $label（$gproject/$gbranch 已经导入过了）"
        return 0
    fi
    head=$(git -C "$pushdir" rev-parse HEAD)
    if [ "$dry" = 1 ]; then
        gerrit_info "[dry] $label: push $head -> $gproject refs/heads/$gbranch"
        return 0
    fi
    gerrit_info "==> 导入 $label（$head -> $gproject/$gbranch）"
    # 退出码必须取 git 自己的：不能 `git push | grep ...`（那样拿到的是 grep 的），
    # 也不能把输出吞掉（失败时用户得看见 gerrit 的原话）
    push_log="$work/push.log"
    if GIT_SSH_COMMAND=$(gerrit_git_ssh_admin "$root") \
        git -C "$pushdir" push "ssh://$GERRIT_ADMIN@127.0.0.1:$GERRIT_SSH_PORT/$gproject.git" \
        "HEAD:refs/heads/$gbranch" > "$push_log" 2>&1; then
        # 成功：把 commit-message-length-validator 的唠叨折掉，留收尾几行
        grep -vE '^remote: (commit [0-9a-f]+: warning|   )' "$push_log" | tail -3 || true
        return 0
    fi
    cat "$push_log"
    gerrit_info "    !! $label 推送失败"
    failed=$((failed + 1))
    return 0
}

# ---------------------------------------------------------------------------
# 清单仓：.repo/manifests（它不在自己的 default.xml 里）
# ---------------------------------------------------------------------------
manifests="$root/.repo/manifests"
if [ -d "$manifests/.git" ]; then
    mname=$(git -C "$manifests" remote get-url origin 2>/dev/null | sed -e 's#.*/##' -e 's#\.git$##')
    [ -n "$mname" ] || mname=$GERRIT_CONTAINER-manifests
    murl=$(git -C "$manifests" remote get-url origin 2>/dev/null || true)
    # github.com:22 这台机器上有时被拦（见 AGENTS.md 的代理一节），
    # 备一个 https 端点：只是 fetch/clone，不需要凭据
    hurl=$(printf '%s' "$murl" |
           sed -e 's#^ssh://git@github.com/#https://github.com/#' \
               -e 's#^git@github.com:#https://github.com/#')
    # 上游分支名：wtool（本地那份 branch 叫 default，别拿它当上游名）
    mbranch=$(git -C "$manifests" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null |
              sed -e 's#^[^/]*/##')
    [ -n "$mbranch" ] || mbranch=main

    if [ "$(git -C "$manifests" rev-parse --is-shallow-repository)" = true ]; then
        if [ "$dry" = 1 ]; then
            gerrit_info "[dry] 清单仓是浅克隆：先补全历史，补不回来就临时克隆一份来推"
        else
            gerrit_info "==> 清单仓是浅克隆，先补全历史（push 不允许从浅克隆发）"
            git -C "$manifests" fetch --unshallow >/dev/null 2>&1 || true
            if [ "$(git -C "$manifests" rev-parse --is-shallow-repository)" = true ] &&
               [ "$hurl" != "$murl" ]; then
                git -C "$manifests" fetch --unshallow "$hurl" >/dev/null 2>&1 || true
            fi
        fi
    fi

    if [ "$(git -C "$manifests" rev-parse --is-shallow-repository)" = false ]; then
        gerrit_import_one "$manifests" "allinkernel/$mname" main "清单仓(.repo/manifests)"
    elif [ "$dry" = 1 ]; then
        gerrit_info "[dry] 清单仓补不全：临时 clone 一份完整的再推 allinkernel/$mname"
    else
        # 浅克隆补不回来（当初是 --depth 拉的，边界对象上游也可能没有）：
        # 临时克隆一份完整裸仓，从它推。数据只有一份，推完就删。
        gerrit_info "==> 清单仓补不全，临时克隆一份完整的来推"
        git clone --bare -q -b "$mbranch" "${hurl:-$murl}" "$work/manifests.git" \
            || gerrit_die "临时克隆清单仓失败（$hurl）"
        gerrit_import_one "$manifests" "allinkernel/$mname" main "清单仓(临时克隆)" \
            "$work/manifests.git"
    fi
fi

# ---------------------------------------------------------------------------
# 清单里的项目
#
# fd 3 喂循环，而不是 `... | while read`：循环体里的 ssh 会把管道的 stdin
# 一起吃掉，读两行就静默停下（第一次跑就踩了：只导入了第一个项目）。
# ---------------------------------------------------------------------------
gerrit_manifest_list "$root" > "$work/manifest.tsv"
while IFS="$(printf '\t')" read -r path name branch remote url <&3; do
    [ -n "${path:-}" ] || continue
    dir="$root/$path"
    gproject=${name%.git}
    gbranch=${branch:-main}

    if reason=$(gerrit_skip_reason "$path" "$name"); then
        gerrit_info "跳过 $path（$reason）"
        continue
    fi
    if [ ! -d "$dir/.git" ]; then
        gerrit_info "跳过 $path（不是 git 仓库，可能是发布包形态）"
        continue
    fi
    if [ "$(git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
        gerrit_info "跳过 $path（浅克隆，git 不允许从浅克隆推）"
        continue
    fi
    gerrit_import_one "$dir" "$gproject" "$gbranch" "$path"
done 3< "$work/manifest.tsv"

gerrit_info ""
if [ "$failed" -gt 0 ]; then
    gerrit_info "==> 有 $failed 个项目没导进去（上面的 !! 行）。其余都在：$(gerrit_web_url)/admin/repos"
    exit 1
fi
gerrit_info "==> 导入完事。看一眼：$(gerrit_web_url)/admin/repos"
