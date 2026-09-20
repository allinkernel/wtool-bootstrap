#!/bin/sh
# lib.sh —— docker24（polygerrit）脚本族的公共部分
#
# 只做三件事：定义常量、拼 ssh 命令、等 gerrit 起来。
# 别的脚本都 `. "$here/lib.sh"` 之后直接用下面的函数。
#
# 所有名字都允许用环境变量覆盖（比如想在别的端口再起一套）：
#   WTOOL_GERRIT_CONTAINER  容器名            默认 docker24
#   WTOOL_GERRIT_IMAGE      镜像              默认 gerritcodereview/gerrit:3.14.3-ubuntu24
#   WTOOL_GERRIT_WEB_PORT   网页端口          默认 8080（只绑 127.0.0.1）
#   WTOOL_GERRIT_SSH_PORT   ssh 端口          默认 29418（只绑 127.0.0.1）
#   WTOOL_GERRIT_ROOT       工作区根          默认：脚本往上找到的工作区
#   WTOOL_GERRIT_AGENT      我用哪个账号推   默认 dsh-agent
#   WTOOL_GERRIT_REVIEWER   你（+2 的人）     默认 mindul
set -eu

GERRIT_CONTAINER=${WTOOL_GERRIT_CONTAINER:-docker24}
GERRIT_IMAGE=${WTOOL_GERRIT_IMAGE:-gerritcodereview/gerrit:3.14.3-ubuntu24}
GERRIT_WEB_PORT=${WTOOL_GERRIT_WEB_PORT:-8080}
GERRIT_SSH_PORT=${WTOOL_GERRIT_SSH_PORT:-29418}
GERRIT_AGENT=${WTOOL_GERRIT_AGENT:-dsh-agent}
GERRIT_REVIEWER=${WTOOL_GERRIT_REVIEWER:-mindul}
GERRIT_ADMIN=admin

# 数据卷：镜像是按 /var/gerrit/{git,etc,db,index,cache} 声明 VOLUME 的，
# 不给它显式命名卷的话 docker 会替你建一堆匿名卷 —— 下次删容器数据就跟着
# 找不着了（这个坑真踩过：一个 --rm 的临时容器看到的是空站点）。
GERRIT_VOLUMES="git etc db index cache"

gerrit_die () { printf '%s\n' "错误: $*" >&2; exit 1; }
gerrit_info () { printf '%s\n' "$*"; }

# 工作区根：从脚本位置往上找到有 .repo 的那层
gerrit_find_root () {
    if [ -n "${WTOOL_GERRIT_ROOT:-}" ]; then
        printf '%s\n' "$WTOOL_GERRIT_ROOT"
        return 0
    fi
    d=$(cd -- "$1" && pwd)
    while [ "$d" != "/" ]; do
        if [ -d "$d/.repo" ]; then
            printf '%s\n' "$d"
            return 0
        fi
        d=$(dirname -- "$d")
    done
    return 1
}

gerrit_require_docker () {
    command -v docker >/dev/null 2>&1 || gerrit_die "没装 docker"
    docker info >/dev/null 2>&1 || gerrit_die "docker 连不上（daemon 没跑？）"
}

gerrit_container_state () {
    # 别写成 `docker inspect ... || printf absent`：容器不存在时 inspect
    # 会往 stdout 吐一个空行再失败，于是拿到的状态是 "\nabsent"，
    # case 就匹配不上了（这个坑真踩了：--recreate 在 rm 之后自己卡死）
    st=$(docker inspect -f '{{.State.Status}}' "$GERRIT_CONTAINER" 2>/dev/null |
         head -1 | tr -d '[:space:]')
    if [ -n "$st" ]; then printf '%s\n' "$st"; else printf 'absent\n'; fi
}

gerrit_ensure_volumes () {
    for v in $GERRIT_VOLUMES; do
        docker volume inspect "$GERRIT_CONTAINER-$v" >/dev/null 2>&1 ||
            docker volume create "$GERRIT_CONTAINER-$v" >/dev/null
    done
}

# 站点密钥/密码/客户端配置都放这里（不是 git 仓库，别提交）
gerrit_home () {
    printf '%s\n' "${WTOOL_GERRIT_HOME:-$1/.gerrit}"
}

gerrit_admin_key () { printf '%s\n' "$(gerrit_home "$1")/keys/gerrit-admin_rsa"; }
gerrit_agent_key () { printf '%s\n' "$(gerrit_home "$1")/keys/$GERRIT_AGENT"'_rsa'; }
gerrit_admin_pw_file () { printf '%s\n' "$(gerrit_home "$1")/admin-http-password"; }

# 用 admin 身份跑一条 gerrit ssh 命令（导入历史、建项目、改配置都靠它）
gerrit_admin_ssh () {
    root=$1; shift
    ssh -i "$(gerrit_admin_key "$root")" \
        -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \
        -o UserKnownHostsFile="${WTOOL_GERRIT_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}" \
        -p "$GERRIT_SSH_PORT" "$GERRIT_ADMIN@127.0.0.1" "$@"
}

# 用 agent 身份（只有 refs/for/* 权限的那个）
gerrit_agent_ssh () {
    root=$1; shift
    ssh -i "$(gerrit_agent_key "$root")" \
        -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \
        -p "$GERRIT_SSH_PORT" "$GERRIT_AGENT@127.0.0.1" "$@"
}

# git 走 gerrit 时要用的 GIT_SSH_COMMAND（value 形式，调用方 export）
gerrit_git_ssh_admin () {
    root=$1
    printf 'ssh -i %s -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -p %s' \
        "$(gerrit_admin_key "$root")" "$GERRIT_SSH_PORT"
}

gerrit_web_url () { printf 'http://127.0.0.1:%s' "$GERRIT_WEB_PORT"; }

gerrit_wait_ready () {
    i=0
    while [ "$i" -lt 90 ]; do
        if curl -fsS -o /dev/null "$(gerrit_web_url)/config/server/version" 2>/dev/null; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    gerrit_die "等了 90 秒 gerrit 还没起来：docker logs $GERRIT_CONTAINER"
}

# 用 REST 改 All-Projects 的 ACL（走 admin 的 http 密码，避免 cookie 的 CSRF 麻烦）
gerrit_admin_rest () {
    root=$1; method=$2; path=$3; body=${4:-}
    pw=$(cat "$(gerrit_admin_pw_file "$root")")
    if [ -n "$body" ]; then
        curl -fsS -u "$GERRIT_ADMIN:$pw" -X "$method" -H 'Content-Type: application/json' \
            --data-binary "$body" "$(gerrit_web_url)/a$path"
    else
        curl -fsS -u "$GERRIT_ADMIN:$pw" -X "$method" "$(gerrit_web_url)/a$path"
    fi
}

# manifest 里的项目清单：path<TAB>name<TAB>branch<TAB>remote<TAB>url
gerrit_manifest_list () {
    root=$1
    python3 "$root/tools/repo/my_repo.py" list --root "$root"
}
