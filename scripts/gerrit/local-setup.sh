#!/bin/sh
# local-setup.sh —— 把工作区接到 docker24 上（每个仓库一条 polygerrit remote + ds_dev 分支）
#
# 做三件事，全部幂等：
#   1. 每个项目加/更新 remote `polygerrit` -> ssh://$GERRIT_AGENT@127.0.0.1:$PORT/<项目>.git
#      （不覆盖 origin/github 等既有 remote —— GitHub 仍然是公开主线）
#   2. 装 gerrit 的 commit-msg hook（推 refs/for/* 必须有 Change-Id）
#   3. 每个项目建分支 ds_dev（从清单声明的那个分支的 tip），并切过去
#
#   sh local-setup.sh              # 全做
#   sh local-setup.sh --no-checkout  # 只建分支，不切
#   sh local-setup.sh --check      # 只报告
#
# 注意：ds_dev 只存在于本地。送检是 `git push polygerrit HEAD:refs/for/<清单分支>`，
# 不是推 ds_dev 这个分支本身。
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
. "$here/lib.sh"

checkout=1; check_only=0
for a in "$@"; do
    case $a in
        --no-checkout) checkout=0 ;;
        --check) check_only=1 ;;
        *) gerrit_die "不认识的参数: $a" ;;
    esac
done

root=$(gerrit_find_root "$here") || gerrit_die "往上找不到工作区根（没有 .repo）"
gerrit_require_docker
gerrit_wait_ready

gerrit_local_one () {   # <dir> <project> <branch> <label>
    dir=$1; gproject=$2; gbranch=$3; label=$4
    url="ssh://$GERRIT_AGENT@127.0.0.1:$GERRIT_SSH_PORT/$gproject.git"

    if [ "$check_only" = 1 ]; then
        cur=$(git -C "$dir" remote get-url polygerrit 2>/dev/null || true)
        [ "$cur" = "$url" ] && gerrit_info "  ok   $label polygerrit" \
                            || gerrit_info "  [缺] $label polygerrit（现在: ${cur:-无}）"
        git -C "$dir" show-ref --verify --quiet refs/heads/ds_dev \
            && gerrit_info "  ok   $label ds_dev" || gerrit_info "  [缺] $label ds_dev"
        return 0
    fi

    if git -C "$dir" remote get-url polygerrit >/dev/null 2>&1; then
        git -C "$dir" remote set-url polygerrit "$url"
    else
        git -C "$dir" remote add polygerrit "$url"
    fi

    hook="$dir/.git/hooks/commit-msg"
    if [ ! -x "$hook" ]; then
        curl -fsS -o "$hook" "$(gerrit_web_url)/tools/hooks/commit-msg" 2>/dev/null &&
            chmod +x "$hook" || gerrit_info "    （$label 的 commit-msg hook 没装上）"
    fi

    if ! git -C "$dir" show-ref --verify --quiet refs/heads/ds_dev; then
        git -C "$dir" branch ds_dev HEAD >/dev/null
        gerrit_info "==> $label: 建了 ds_dev（从 $(git -C "$dir" rev-parse --short HEAD)）"
    fi
    if [ "$checkout" = 1 ]; then
        git -C "$dir" checkout -q ds_dev 2>/dev/null || \
            gerrit_info "    （$label 切到 ds_dev 失败，工作区有改动？）"
    fi
}

# 清单仓自己
manifests="$root/.repo/manifests"
if [ -d "$manifests/.git" ]; then
    mname=$(git -C "$manifests" remote get-url origin 2>/dev/null | sed -e 's#.*/##' -e 's#\.git$##')
    [ -n "$mname" ] || mname=$GERRIT_CONTAINER-manifests
    gerrit_local_one "$manifests" "allinkernel/$mname" main "清单仓"
fi

# fd 3 喂循环：别让循环体里的命令把 stdin 吃掉（见 import.sh 里的同一注释）
gerrit_manifest_list "$root" > "$(gerrit_home "$root")/manifest.tsv"
while IFS="$(printf '\t')" read -r path name branch remote url <&3; do
    [ -n "${path:-}" ] || continue
    dir="$root/$path"
    [ -d "$dir/.git" ] || { gerrit_info "跳过 $path（不是 git 仓库）"; continue; }
    gerrit_local_one "$dir" "${name%.git}" "${branch:-main}" "$path"
done 3< "$(gerrit_home "$root")/manifest.tsv"

gerrit_info ""
gerrit_info "==> 完事。送检一条改动："
gerrit_info "    cd <项目>; git add -A; git commit; git push polygerrit HEAD:refs/for/<清单分支>"
