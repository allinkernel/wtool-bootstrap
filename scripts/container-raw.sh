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
  可以做什么（每一步都是你自己决定要不要跑）

  第 0 步：这个镜像里连 python3 和 git 都没有，wtool 一条都跑不了。
  装它们（用系统自带源，不需要证书）：

      apt-get update && apt-get install -y --no-install-recommends \
          ca-certificates git python3 curl
      git config --global --add safe.directory '*'

  最后那条**不能省**：容器里是 root、仓库属主是宿主用户，
  git 会以 "dubious ownership" 拒绝工作 —— 不设的话你会在完全无关的地方找原因。

  第 1 步：装引擎（自举到 ~/.wtool/bootstrap，并建工作区入口软链）：

      cd /wtool && ./install.sh --force

  它会检查依赖，缺什么会直接告诉你该装什么 —— 不用猜。

  装完 wtool 之后（也可以不装引擎，直接调 /wtool/bootstrap/wtool.sh）：

      wtool table                 看项目表：每个项目支持哪些动作、做到哪一步了
      wtool doctor                看环境和状态目录对不对
      wtool bootstrap             装"不需要决策"的那些（不 build、不 download）
      wtool bootstrap --install-only   只做软链和 rc 注入，不跑 apt（最快）

      wtool build    <项目>       自己编（小时级）
      wtool download <项目>       从发布页拿现成的包
      wtool install  <项目>       登记 + 软链 + shell 集成
      wtool uninstall --id <项目> 撤掉
      wtool publish  <项目>       发到项目自己的 release

  wtool bootstrap 会跑 apt 装系统包；不想动系统就加 --no-system。

  项目自己的脚本住在 <项目>/scripts/ 下，可以直接看、直接跑：
      build.sh  download.sh  install.sh  uninstall（install.sh --uninstall）
      publish.sh  extract.sh
  它们各自干什么，见 wtool-base/README.md 的"脚本做什么"那一节。

  代理：`docker run` 不会把宿主的 HTTP_PROXY 带进容器（除非 -e），
  所以容器里默认是"裸网"。上面已经探测并自动接上了宿主的代理 ——
  不想要就 WTOOL_NO_PROXY=1；宿主的代理不在默认端口就用
  -e WTOOL_HOST_PROXY=http://127.0.0.1:端口。
  （这依赖 --network=host：那时容器里的 127.0.0.1 才是宿主自己。）

  想一步到位得到一个装好的环境，用另一个脚本
  （它会把上面第 0、1 步和 wtool bootstrap 一次做完）：
      bash /wtool/bootstrap/scripts/container-shell.sh
  ────────────────────────────────────────────────────────────

TIP

if command -v bash >/dev/null 2>&1; then
    exec bash
else
    exec sh
fi
