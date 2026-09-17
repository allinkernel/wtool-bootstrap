#!/bin/sh
# container-proxy.sh —— 让容器里的命令能用上**宿主机**的代理。
#
# 由 container-raw.sh / container-shell.sh source 进来。不单独执行。
#
# 为什么需要这个文件：
#   `docker run` **不会**把你 shell 里的环境变量带进容器 —— 除非显式 -e。
#   所以哪怕宿主机里 http_proxy 设得好好的、curl 什么都通，
#   容器里也是"裸网"，所有下载都会失败。
#   而人很容易把它归因成"网络坏了""GitHub 连不上"，去查错方向。
#
# 为什么 127.0.0.1 在容器里能用：
#   这两个脚本都要求 `--network=host`（容器里的 127.0.0.1 就是宿主自己）。
#   这也正是它们必须带 --network=host 的原因之一 ——
#   用默认的 bridge 网络时，容器里的 127.0.0.1 是容器自己，
#   代理地址指过去只会连到一个没人监听的端口。
#
# 探测顺序：
#   1. 容器里已经有代理变量（说明调用方用了 -e 传进来）→ 直接用，什么都不做
#   2. 否则探测常见的本机代理端口 → 通了就设上，并**明确说出来**
#   3. 都没有 → 什么都不做，但提醒一句为什么可能是这个问题
set -eu

# 用户可以用 WTOOL_HOST_PROXY 指定，或者 WTOOL_NO_PROXY=1 关掉自动探测
_CP_PROXY=${WTOOL_HOST_PROXY:-http://127.0.0.1:7897}

# 探测某个 host:port 通不通。
#
# **必须在一个独立的子进程里做，不能在当前 shell 里开 fd。**
# 踩过：原来写的是 `(exec 3<>"/dev/tcp/$1/$2")` 加 `exec 3<&-`，
# 结果这个脚本跑完之后交接给交互 shell（`exec bash -i`）**不给提示符**了 ——
# 光标停在那里，看起来和卡死一模一样。
# 而"卡住"和"在等你输入"分不清，正是这个脚本最该避免的事。
# 排查了很久才定位到是这段 fd 操作的影响。
# 现在的写法：fd 只存在于 `timeout bash -c` 那个子进程里，
# 父 shell 一个 fd 都不碰。
_cp_can_connect() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1 && return 0
    else
        bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1 && return 0
    fi
    command -v nc >/dev/null 2>&1 && nc -z "$1" "$2" >/dev/null 2>&1 && return 0
    return 1
}

container_proxy_setup() {
    # 1) 已经有了就别动 —— 调用方传进来的优先级最高
    if [ -n "${HTTPS_PROXY:-}${https_proxy:-}${HTTP_PROXY:-}${http_proxy:-}" ]; then
        printf '    代理   : 已由 -e 传入 %s\n' \
            "${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-$http_proxy}}}"
        return 0
    fi

    if [ "${WTOOL_NO_PROXY:-0}" = 1 ]; then
        printf '    代理   : 自动探测已关闭（WTOOL_NO_PROXY=1）\n'
        return 0
    fi

    # 2) 探一下宿主代理在不在
    _host=${_CP_PROXY#http://}
    _host=${_host#https://}
    _port=${_host##*:}
    _host=${_host%%:*}
    case $_port in ''|*[!0-9]*) _port=7897 ;; esac
    [ -n "$_host" ] || _host=127.0.0.1

    if _cp_can_connect "$_host" "$_port"; then
        # 大小写都设：不同工具认不同的那个（curl 认小写，有些认大写）
        HTTP_PROXY=$_CP_PROXY  HTTPS_PROXY=$_CP_PROXY
        http_proxy=$_CP_PROXY  https_proxy=$_CP_PROXY
        export HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
        # 本机/内网不要走代理，否则容器内部通信会被绕一圈
        no_proxy=${no_proxy:+$no_proxy,}127.0.0.1,localhost
        NO_PROXY=${NO_PROXY:+$NO_PROXY,}127.0.0.1,localhost
        export no_proxy NO_PROXY
        printf '    代理   : 探测到宿主代理 %s，已自动接上\n' "$_CP_PROXY"
        printf '             （不要的话：WTOOL_NO_PROXY=1 或者 -e WTOOL_HOST_PROXY=...）\n'
        return 0
    fi

    # 3) 没有代理 —— 说清楚后果，别让用户自己猜
    printf '    代理   : 没有（探测过 %s，不通）\n' "$_CP_PROXY"
    printf '             如果这台机器需要代理才能出网，容器里所有下载都会失败。\n'
    printf '             宿主机有代理的话，用这条命令把变量传进来：\n'
    printf '               docker run ... -e HTTP_PROXY -e HTTPS_PROXY -e http_proxy -e https_proxy ...\n'
    printf '             或者用 --network=host 让这个脚本自己探测（默认探 127.0.0.1:7897）。\n'
}
