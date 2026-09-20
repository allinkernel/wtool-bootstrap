#!/bin/sh
# bootstrap.sh —— docker24 的"第一次开机"：账号、权限、密钥
#
# 一台全新的 gerrit 是什么都没有的：没有你的账号、没有我的账号、
# 连 admin 的 ssh key 都没登记（镜像 init 只生成了一个随机 http token）。
# 这个脚本把这些补齐，跑第二遍是 no-op。
#
# 它做四件事：
#   1. 造两把 key：gerrit-admin_rsa（管服务器用）、dsh-agent_rsa（我推代码用）
#   2. 把 admin 的 key 塞进 All-Users.git —— 这一步只能在容器停机时直接写
#      NoteDb（gerrit 没有"还没登录就先注册 key"的通道）
#   3. 建账号：$GERRIT_REVIEWER（你，+2 的人，进 Administrators）
#              $GERRIT_AGENT（我，只能推 refs/for/*）
#   4. 改 All-Projects 的 ACL：refs/heads/* 只给 Administrators push；
#      submit 放给 Registered Users —— 注意**闸门是 Code-Review +2 这个
#      label**（submit-requirement），不是 submit 权限本身：
#      没有你的 +2，谁（包括我）都 submit 不了。
#
#   sh bootstrap.sh            # 全自动
#   sh bootstrap.sh --check    # 只体检，不改
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
. "$here/lib.sh"

check_only=0
[ "${1:-}" = "--check" ] && check_only=1

root=$(gerrit_find_root "$here") || gerrit_die "往上找不到工作区根（没有 .repo）"
home=$(gerrit_home "$root")
gerrit_require_docker

[ "$check_only" = 1 ] || sh "$here/up.sh"
gerrit_wait_ready

# ---------------------------------------------------------------------------
# 1) key
# ---------------------------------------------------------------------------
mkdir -p "$home/keys"

ensure_key () {   # <私钥路径> <注释>
    [ -f "$1" ] && return 0
    if [ "$check_only" = 1 ]; then
        gerrit_info "  [缺] $1"
        return 1
    fi
    ssh-keygen -t rsa -b 3072 -N '' -C "$2" -f "$1" >/dev/null
    gerrit_info "==> 生成 $1"
}

ensure_key "$(gerrit_admin_key "$root")" "gerrit-admin@$GERRIT_CONTAINER"
ensure_key "$(gerrit_agent_key "$root")" "$GERRIT_AGENT@$GERRIT_CONTAINER"

# ---------------------------------------------------------------------------
# 2) admin 的 ssh key：只在 ssh 还不通的时候写 NoteDb
# ---------------------------------------------------------------------------
gerrit_admin_ssh_works () {
    gerrit_admin_ssh "$root" gerrit version >/dev/null 2>&1
}

if gerrit_admin_ssh_works; then
    gerrit_info "==> admin 的 ssh key 已经就位"
elif [ "$check_only" = 1 ]; then
    gerrit_info "  [缺] admin 的 ssh key 还没写进 NoteDb（跑不带 --check 的）"
else
    gerrit_info "==> 停机写 NoteDb：给 admin（第一个账号）登记 ssh key"
    docker stop "$GERRIT_CONTAINER" >/dev/null
    keys=$(dirname "$(gerrit_admin_key "$root")")
    docker run --rm -u 0 \
        -v "$GERRIT_CONTAINER-git:/git" \
        -v "$keys:/keys:ro" \
        --entrypoint sh "$GERRIT_IMAGE" -c '
set -eu
export HOME=/tmp
printf "[safe]\n\tdirectory = *\n" > /tmp/gitconfig
export GIT_CONFIG_GLOBAL=/tmp/gitconfig
export GIT_AUTHOR_NAME="Gerrit Bootstrap" GIT_AUTHOR_EMAIL="admin@example.com"
export GIT_COMMITTER_NAME="Gerrit Bootstrap" GIT_COMMITTER_EMAIL="admin@example.com"
cd /git/All-Users.git
# 第一个（id 最小）的账号就是 init 建的那个管理员。
# 注意别自己拼 shard 目录：gerrit 的规则是 id 的**十进制末两位**
# （1000000 -> 00、1000002 -> 02），拼错了会静默建出个孤立的 ref。
ref=$(git for-each-ref --format="%(refname)" refs/users/ \
      | sort -t/ -k4,4n | head -1)
[ -n "$ref" ] || { echo "All-Users 里一个账号都没有？" >&2; exit 1; }
echo "  目标账号 ref: $ref"
export GIT_INDEX_FILE=/tmp/idx
git read-tree "$ref"
rm -f /tmp/authorized_keys
git cat-file -p "$ref:authorized_keys" > /tmp/authorized_keys 2>/dev/null || true
cat /keys/gerrit-admin_rsa.pub >> /tmp/authorized_keys
blob=$(git hash-object -w /tmp/authorized_keys)
git update-index --add --cacheinfo 100644,$blob,authorized_keys
tree=$(git write-tree)
parent=$(git rev-parse "$ref")
commit=$(git commit-tree "$tree" -p "$parent" -m "Add SSH key for the initial admin user")
git update-ref "$ref" "$commit"
git ls-tree "$ref"
'
    docker start "$GERRIT_CONTAINER" >/dev/null
    gerrit_wait_ready
    gerrit_admin_ssh_works || gerrit_die "key 写完了但 ssh 还是不通，看 docker logs"
    gerrit_info "==> admin 的 ssh 已经通了"
fi

# ---------------------------------------------------------------------------
# 3) 账号
# ---------------------------------------------------------------------------
account_exists () {   # <username>
    pw=$(cat "$(gerrit_admin_pw_file "$root")" 2>/dev/null || printf '')
    [ -n "$pw" ] || return 1
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "$GERRIT_ADMIN:$pw" \
        "$(gerrit_web_url)/a/accounts/$1")
    [ "$code" = 200 ]
}

# admin 的 http 密码（REST 改 ACL 要用）
if [ ! -f "$(gerrit_admin_pw_file "$root")" ]; then
    if [ "$check_only" = 1 ]; then
        gerrit_info "  [缺] admin 的 http 密码文件"
    else
        pw=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
        gerrit_admin_ssh "$root" gerrit set-account "$GERRIT_ADMIN" --http-password "$pw" >/dev/null
        printf '%s\n' "$pw" > "$(gerrit_admin_pw_file "$root")"
        chmod 600 "$(gerrit_admin_pw_file "$root")"
        gerrit_info "==> 给 admin 设了 http 密码（存在 $(gerrit_admin_pw_file "$root")）"
    fi
fi

if [ "$check_only" = 1 ]; then
    # 体检模式：只报告账号/权限现状，不动任何东西
    for u in "$GERRIT_REVIEWER" "$GERRIT_AGENT"; do
        if account_exists "$u"; then
            gerrit_info "  ok   $u 已存在"
        else
            gerrit_info "  [缺] $u"
        fi
    done
    if account_exists "$GERRIT_REVIEWER" &&
       gerrit_admin_ssh "$root" gerrit ls-members Administrators </dev/null 2>/dev/null |
       grep -q "	$GERRIT_REVIEWER	"; then
        gerrit_info "  ok   $GERRIT_REVIEWER 在 Administrators（有 +2 权限）"
    else
        gerrit_info "  [缺] $GERRIT_REVIEWER 还没进 Administrators"
    fi
fi

if [ "$check_only" = 0 ]; then
    if account_exists "$GERRIT_REVIEWER"; then
        gerrit_info "==> 账号 $GERRIT_REVIEWER 已存在"
    else
        gerrit_admin_ssh "$root" gerrit create-account "$GERRIT_REVIEWER" \
            --full-name "$GERRIT_REVIEWER" --email "$GERRIT_REVIEWER@example.com" >/dev/null
        gerrit_info "==> 建了账号 $GERRIT_REVIEWER"
    fi
    # 你的 +2 靠 Administrators 组（默认 ACL 里只有这个组能 +2）
    gerrit_admin_ssh "$root" gerrit set-members --add "$GERRIT_REVIEWER" Administrators >/dev/null

    if account_exists "$GERRIT_AGENT"; then
        gerrit_info "==> 账号 $GERRIT_AGENT 已存在"
    else
        cat "$(gerrit_agent_key "$root").pub" | gerrit_admin_ssh "$root" \
            gerrit create-account "$GERRIT_AGENT" --full-name "$GERRIT_AGENT" \
            --email "$GERRIT_AGENT@example.com" --ssh-key - >/dev/null
        gerrit_info "==> 建了账号 $GERRIT_AGENT"
    fi

    # 我推的提交 author 是你（forge author 允许），committer 也是你 ——
    # 所以你的邮箱要登记在 agent 账号上，否则 gerrit 会拒收。
    user_email=$(git config --global user.email 2>/dev/null || true)
    if [ -n "$user_email" ]; then
        gerrit_admin_ssh "$root" gerrit set-account "$GERRIT_AGENT" \
            --add-email "$user_email" >/dev/null 2>&1 || true
        gerrit_info "==> $GERRIT_AGENT 名下登记了 $user_email（让你原来的 git 身份还能提交）"
    fi
fi

# ---------------------------------------------------------------------------
# 4) ACL
# ---------------------------------------------------------------------------
if [ "$check_only" = 0 ]; then
    pw=$(cat "$(gerrit_admin_pw_file "$root")")
    gerrit_admin_rest "$root" POST /projects/All-Projects/access '{
  "add": {
    "refs/heads/*": {
      "permissions": {
        "push":   { "rules": { "Administrators":        { "action": "ALLOW" } } },
        "submit": { "rules": { "global:Registered-Users": { "action": "ALLOW" } } }
      }
    }
  }
}' >/dev/null
    gerrit_info "==> All-Projects ACL 就位（push=Administrators，submit=Registered Users）"
fi

gerrit_info ""
gerrit_info "==> 完事。你这边要做的一步："
gerrit_info "    浏览器打开 $(gerrit_web_url)/login/?user_name=$GERRIT_REVIEWER"
gerrit_info "    （用 $GERRIT_REVIEWER 登录 = 有 +2 / Submit 权限）"
gerrit_info "    Admin: 也可以直接 $(gerrit_web_url)/login/?account_id=1000000"
