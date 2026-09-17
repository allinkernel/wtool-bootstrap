#!/bin/sh
# container-shell.sh —— 在容器里一步到位：装 wtool，然后交给你。
#
# 宿主机执行（一条命令）：
#   docker run --rm -it --network=host \
#     -v ~/self/wtool:/wtool:ro \
#     ubuntu:24.04 bash /wtool/bootstrap/scripts/container-shell.sh
#
# 它只做三件事，和你在真机上手动做的一模一样：
#
#   1. ./install.sh          准备运行环境 + 装 wtool 自己（不装任何项目）
#   2. 交给你一个 shell      让当前 shell 认识 wtool
#   3. 你跑 wtool bootstrap  装那些不需要你决策的项目
#
# **第 3 步故意不替你做。** "让工具能用"和"装哪些项目"是两件事，
# 失败原因也完全不同，混在一条命令里用户看到一屏输出分不清该修哪头。
#
# 环境探测全在 install.sh 里（它自己认系统、认缺什么包、认要不要接代理），
# 这个脚本**不重复那些逻辑** —— 重复了迟早两边说不一样的话。
#
# 为什么必须 --network=host：
#   容器里的 127.0.0.1 是容器自己。要探宿主代理并接上，
#   只有 host 网络下 127.0.0.1 才指向宿主。
set -eu

WTOOL_DIR=${WTOOL_DIR:-/wtool}
GIT_OPTIONAL_LOCKS=0
export GIT_OPTIONAL_LOCKS

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }

[ -d "$WTOOL_DIR/bootstrap" ] || {
    warn "$WTOOL_DIR 下没有 bootstrap/ —— 挂载点不对？"
    warn "宿主机应该是：docker run ... -v ~/self/wtool:$WTOOL_DIR:ro ..."
    exit 1
}

# 代理：docker run 不会把宿主的 HTTP_PROXY 带进容器（除非 -e）。
# 探一次并接上（依赖 --network=host）。不想要：-e WTOOL_NO_PROXY=1
if [ -f "$(dirname -- "$0")/container-proxy.sh" ]; then
    # shellcheck disable=SC1091
    . "$(dirname -- "$0")/container-proxy.sh"
    container_proxy_setup
fi

say "第 1 步：cd $WTOOL_DIR && ./install.sh"
if ! ( cd -- "$WTOOL_DIR" && ./install.sh ); then
    warn "install.sh 失败了 —— 上面就是原因。"
    warn "它是「让 wtool 能用」那一步，不成功的话下面也用不了。"
    warn "已经进到容器里了，可以自己接着排查；当前目录 $WTOOL_DIR"
fi

cat <<'TIP'

  ────────────────────────────────────────────────────────────
  第 2 步：下面这个提示符就是在等你。

  让当前 shell 认识 wtool（PATH 是 shell 启动时定下的）：

      exec $SHELL          # 或者干脆重开一个终端

  第 3 步：装那些不需要你决策的项目

      wtool                # 先看项目表
      wtool bootstrap      # 再装

  wtool bootstrap 不 build、不 download —— 需要先产出东西的项目会被跳过
  并列出来，让你自己决定跑哪条：

      wtool download <项目>   从发布页拿现成的包（分钟级）
      wtool build    <项目>   自己编（小时级）
      wtool install  <项目>
  ────────────────────────────────────────────────────────────

TIP

# 交接给交互 shell。为什么必须 -i，见 container-raw.sh 里同样的注释。
if command -v bash >/dev/null 2>&1; then
    exec bash -i
else
    exec sh -i
fi
