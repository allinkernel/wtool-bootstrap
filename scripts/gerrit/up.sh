#!/bin/sh
# up.sh —— 起 docker24：工作区里那台 polygerrit（Gerrit）服务器
#
# 幂等：跑第二遍什么都不做。容器用 --restart unless-stopped，
# 机器重启后自己会回来。
#
#   sh up.sh            # 起（不在就 run，在就 start，跑着就退出）
#   sh up.sh --recreate # 删了重建（改了端口/镜像/挂载时用；数据在命名卷里，不丢）
#
# 挂载：
#   命名卷 docker24-{git,etc,db,index,cache} -> /var/gerrit/*（站点数据）
#   工作区                                  -> /wtool（只读地给进去，方便在容器里看清单/导入）
# 端口只绑 127.0.0.1：这是给本机检视用的，不该暴露到局域网。
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
. "$here/lib.sh"

recreate=0
[ "${1:-}" = "--recreate" ] && recreate=1

root=$(gerrit_find_root "$here") || gerrit_die "往上找不到工作区根（没有 .repo）"
gerrit_require_docker
gerrit_ensure_volumes

if [ "$recreate" = 1 ] && [ "$(gerrit_container_state)" != absent ]; then
    gerrit_info "==> 删掉旧容器 $GERRIT_CONTAINER（数据在卷里，不丢）"
    docker rm -f "$GERRIT_CONTAINER" >/dev/null
fi

case $(gerrit_container_state) in
    running)
        gerrit_info "==> $GERRIT_CONTAINER 已经在跑"
        ;;
    exited|created|paused)
        gerrit_info "==> 启动已存在的容器 $GERRIT_CONTAINER"
        docker start "$GERRIT_CONTAINER" >/dev/null
        ;;
    absent)
        gerrit_info "==> 创建容器 $GERRIT_CONTAINER（镜像 $GERRIT_IMAGE）"
        set -- 
        for v in $GERRIT_VOLUMES; do
            set -- "$@" -v "$GERRIT_CONTAINER-$v:/var/gerrit/$v"
        done
        docker run -d --name "$GERRIT_CONTAINER" \
            --restart unless-stopped \
            -p "127.0.0.1:$GERRIT_WEB_PORT:8080" \
            -p "127.0.0.1:$GERRIT_SSH_PORT:29418" \
            "$@" \
            -v "$root:/wtool:ro" \
            -e "CANONICAL_WEB_URL=$(gerrit_web_url)/" \
            -e "HTTPD_LISTEN_URL=http://0.0.0.0:8080/" \
            "$GERRIT_IMAGE" >/dev/null
        ;;
    *)
        gerrit_die "$GERRIT_CONTAINER 状态是 $(gerrit_container_state)，不认识了"
        ;;
esac

gerrit_wait_ready
gerrit_info "==> gerrit 就绪：$(gerrit_web_url)/"
gerrit_info "    ssh 端点：ssh -p $GERRIT_SSH_PORT $GERRIT_AGENT@127.0.0.1 gerrit version"
