#!/bin/sh
# 进一个"刚 repo sync 完"的容器：**只挂工作区，什么都不装**。
#
# 宿主机执行：
#   docker run --rm -it --network=host \
#     -v ~/self/wtool:/wtool:ro \
#     ubuntu:20.04 bash /wtool/bootstrap/scripts/container-raw.sh
#
# 和 container-shell.sh 的分工：
#
#   container-shell.sh   装系统依赖 → 装 wtool 引擎 → 跑 wtool bootstrap
#                        （把所有不需要决策的项目都装上）→ 进 zsh
#                        用途：想马上得到一个能用的环境
#
#   container-raw.sh     **一个都不装**，只把工作区挂进来 → 进 bash
#                        用途：从零走一遍流程，每一步都自己决定
#                        状态等价于"刚 repo sync 完，什么都没发生"
#
# 这里**故意不装 python3**。装了它 wtool.sh 就能跑，而"刚 sync 完"的机器
# 本来就还没有 python3 —— 这个容器要如实反映那个状态。否则你会以为某条命令
# 能用，换到真机器上才发现不能，那才是真的浪费时间。
#
# 进来之后能做什么，脚本末尾会打一份对照表；man 版见 wtool-base/README.md。
set -eu

WTOOL_DIR=${WTOOL_DIR:-/wtool}
export GIT_OPTIONAL_LOCKS

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }

[ -d "$WTOOL_DIR/bootstrap" ] || {
    warn "$WTOOL_DIR 下没有 bootstrap/ —— 挂载点不对？"
    warn "宿主机应该是：docker run ... -v ~/self/wtool:$WTOOL_DIR:ro ..."
    exit 1
}

# ─────────────────────────────────────────────────────────────
say "只挂工作区，不装任何东西"
printf '    工作区 : %s（只读挂载）\n' "$WTOOL_DIR"
printf '    用户   : %s\n' "$(id -un 2>/dev/null || echo '?')"
printf '    系统   : %s\n' "$(. /etc/os-release 2>/dev/null && printf '%s %s' "$ID" "$VERSION_ID")"
printf '    项目数 : %s\n' "$(ls -d "$WTOOL_DIR"/*/ 2>/dev/null | grep -v '^\.' | wc -l | tr -d ' ')"

# ─────────────────────────────────────────────────────────────
# 只设 GIT_OPTIONAL_LOCKS，**不设 safe.directory**。
#
# 曾经在这里设过 safe.directory —— 但那一刻 git 还没装（这个容器什么都不装），
# 命令静默失败，用户后面还是撞上 "dubious ownership"。
# 现在把它放进下面的第 0 步命令里，跟着 git 一起装完再设，顺序才对。
GIT_OPTIONAL_LOCKS=0
printf '    GIT_OPTIONAL_LOCKS=0 ✓（只读挂载也能跑 git 命令）\n'
printf '    safe.directory 没设 —— 它得等 git 装好之后，见下面第 0 步\n'

# ─────────────────────────────────────────────────────────────
# 代理：`docker run` **不会**把宿主 shell 里的环境变量带进容器，除非显式 -e。
# 所以容器里默认是"裸网" —— 宿主 curl 什么都通，容器里却全失败，
# 而人很容易把它归因成"网络坏了"，去查错方向。
# 这里探一次：已有变量就用（-e 传进来的），没有就试宿主代理
# （要求 --network=host，此时容器里的 127.0.0.1 就是宿主自己）。
# ─────────────────────────────────────────────────────────────
if [ -f "$(dirname -- "$0")/container-proxy.sh" ]; then
    . "$(dirname -- "$0")/container-proxy.sh"
    container_proxy_setup
fi

# ─────────────────────────────────────────────────────────────
say "环境现状（这是重点：下面这些都还没做）"
for c in python3 git curl ansible-playbook zsh tmux rg nvim wtool; do
    if command -v "$c" >/dev/null 2>&1; then
        printf '    %-16s %s\n' "$c" "$(command -v "$c")"
    else
        printf '    %-16s \033[33m没有\033[0m\n' "$c"
    fi
done

cat <<'TIP'

  ────────────────────────────────────────────────────────────
  这个容器里什么都没装 —— 等价于"刚 repo sync 完"。
  接下来三条命令，和你在真机上做的一模一样：

      cd /wtool && ./install.sh     # 准备环境 + 装 wtool 自己
      exec $SHELL                   # 让当前 shell 认识 wtool
      wtool bootstrap               # 装不需要你决策的项目

  第一条会自动认系统、认缺什么包、认要不要接代理 —— 不用你操心。
  想看它到底干了什么：./install.sh --dry-run
  ────────────────────────────────────────────────────────────

TIP

if command -v bash >/dev/null 2>&1; then
    exec bash -i
else
    exec sh -i
fi
