#!/bin/sh
# 进一个"刚 repo sync 完"的容器：**只挂工作区，什么都不装**。
#
# 宿主机执行：
#   docker run --rm -it --network=host \
#     -v ~/self/wtool:/wtool:ro \
#     ubuntu:20.04 bash /wtool/bootstrap/scripts/container-raw.sh
#
# 想**以普通用户**进容器（而不是 root），加 `--user`：
#   docker run --rm -it --network=host \
#     -v ~/self/wtool:/wtool:ro \
#     ubuntu:24.04 bash /wtool/bootstrap/scripts/container-raw.sh --user mindul
#
#   `--user <名字>` 会（顺序有意义）：
#     1. 先照 install-env.sh 那套**测速挑 apt 源**（结果记进新用户的 state，
#        install.sh 之后直接接着用，不再测第二遍）
#     2. 装 sudo（基础镜像里**没有**它，不装就没法 sudo apt-get）
#     3. 建这个用户（家目录、bash、密码 root、sudo 免密）
#     4. `su - <名字>` 进它的 shell —— 后面所有命令都是普通用户跑的
#   这是唯一会让本脚本"装点东西"的开关；不带 --user 时行为一个字没变。
#
# 和 container-shell.sh 的分工：
#
#   container-shell.sh   装系统依赖 → 装 wtool 引擎 → 交给你（sudo-bootstrap + bootstrap）
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

usage() {
    cat <<'USAGE'
用法: container-raw.sh [--user <用户名>]

  --user <用户名>   在容器里建一个普通用户（密码 root、sudo 免密），然后以它进 shell。
                    用户名要能当 Linux 用户名用：[a-z_][a-z0-9_-]*（小写字母开头）。
                    不带这个参数就是老行为：root 进去，什么都不装。
  -h, --help        打这份用法。
USAGE
}

USER_NAME=""
while [ $# -gt 0 ]; do
    case $1 in
        --user)   USER_NAME=${2:-}
                  [ -n "$USER_NAME" ] || { warn "--user 后面要给用户名"; usage; exit 2; }
                  shift 2 ;;
        --user=*) USER_NAME=${1#--user=}
                  [ -n "$USER_NAME" ] || { warn "--user 后面要给用户名"; usage; exit 2; }
                  shift ;;
        -h|--help) usage; exit 0 ;;
        *) warn "不认识的参数: $1"; usage; exit 2 ;;
    esac
done
if [ -n "$USER_NAME" ]; then
    case $USER_NAME in
        [a-z_]*) ;;
        *) warn "用户名 $USER_NAME 不像个 Linux 用户名（要小写字母或下划线开头）"; exit 2 ;;
    esac
    case $USER_NAME in
        *[!a-z0-9_-]*) warn "用户名 $USER_NAME 里有不合法字符（只允许 a-z 0-9 _ -）"; exit 2 ;;
    esac
    [ "$(id -u)" = 0 ] || { warn "--user 要在容器里以 root 身份跑（建用户、装 sudo 都要 root）"; exit 2; }
    [ "$USER_NAME" != root ] || { warn "--user root 没意义（不带 --user 就是 root）"; exit 2; }
fi

[ -d "$WTOOL_DIR/bootstrap" ] || {
    warn "$WTOOL_DIR 下没有 bootstrap/ —— 挂载点不对？"
    warn "宿主机应该是：docker run ... -v ~/self/wtool:$WTOOL_DIR:ro ..."
    exit 1
}

# ─────────────────────────────────────────────────────────────
say "只挂工作区，不装任何东西"
printf '    工作区 : %s（只读挂载）\n' "$WTOOL_DIR"
printf '    用户   : %s\n' "$(id -un 2>/dev/null || echo '?')$([ -n "$USER_NAME" ] && printf '（装完切成 %s）' "$USER_NAME")"
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

# ─────────────────────────────────────────────────────────────
# --user：建用户（唯一会装东西的开关）
#
# 为什么非要装 sudo：ubuntu 基础镜像里**没有** sudo（实测），没有它
# `sudo apt-get update` 直接 command not found。装它要 apt-get update，
# 所以顺手借用 install-env.sh 那套"测速 → 挑源"—— 顺便把选择记进
# **新用户的 state 目录**，install.sh 之后读到就直接用（ADR-0032 / 见
# install-env.sh 里"上次挑过就接着用"那段），不会在这台机器上测第二遍。
# ─────────────────────────────────────────────────────────────
if [ -n "$USER_NAME" ]; then
    say "--user $USER_NAME：装 sudo + 建用户（密码 root、sudo 免密）"
    USER_HOME="/home/$USER_NAME"

    # ① **先建用户**，顺序很重要（实测踩过）：
    #    如果先做"挑源"那一步，它会以 root 身份 mkdir 出
    #    /home/$USER/.local/...，于是 `useradd -m` 看到家目录已存在就**不再 chown**，
    #    结果用户连自己家目录都写不了（`mkdir ~/.wtool` → Permission denied）。
    if id -u "$USER_NAME" >/dev/null 2>&1; then
        printf '    用户   : %s 已经在了（复用）\n' "$USER_NAME"
    else
        # 尽量用**宿主那个 uid/gid**：挂进来的工作区归它，
        # git 才不会说 "dubious ownership"（uid 不一致时 `wtool install` 直接拒绝）。
        _uid_args=""; _gid_args=""
        _ws_uid=$(stat -c %u "$WTOOL_DIR" 2>/dev/null || echo "")
        _ws_gid=$(stat -c %g "$WTOOL_DIR" 2>/dev/null || echo "")
        if [ -n "$_ws_uid" ] && [ "$_ws_uid" != 0 ]; then
            _holder=$(getent passwd "$_ws_uid" 2>/dev/null | cut -d: -f1 || true)
            if [ "$_holder" = "ubuntu" ]; then
                # 基础镜像自带一个 ubuntu(1000)，把 uid 让出来（容器里删它没有副作用）
                if userdel -r ubuntu >/dev/null 2>&1; then
                    printf '    清理   : 删掉镜像自带的 ubuntu 用户，把 uid %s 让给 %s\n' \
                        "$_ws_uid" "$USER_NAME"
                    _holder=""
                fi
            fi
            if [ -z "$_holder" ]; then
                _uid_args="-u $_ws_uid"
                if [ -n "$_ws_gid" ] && ! getent group "$_ws_gid" >/dev/null 2>&1; then
                    groupadd -g "$_ws_gid" "$USER_NAME" 2>/dev/null && _gid_args="-g $USER_NAME"
                fi
            else
                warn "  宿主工作区属于 uid $_ws_uid，可它被容器里的 $_holder 占着 —— 换个 uid 建，git 那道坎交给 safe.directory"
            fi
        fi
        # shellcheck disable=SC2086
        useradd -m -s /bin/bash $_uid_args $_gid_args "$USER_NAME" \
            || { warn "  建用户失败（useradd）"; exit 1; }
        printf '    用户   : %s 建好了（uid %s）\n' "$USER_NAME" "$(id -u "$USER_NAME")"
    fi
    if printf '%s:%s\n' "$USER_NAME" "root" | chpasswd; then
        printf '    密码   : root\n'
    else
        warn "  设密码失败（chpasswd）"
    fi
    # sudo 免密：脚本里跑 sudo 不该卡在等输入上（和引擎"非交互要能跑"的规矩一致）
    usermod -aG sudo "$USER_NAME" 2>/dev/null || true
    mkdir -p /etc/sudoers.d
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USER_NAME" > "/etc/sudoers.d/90-$USER_NAME"
    chmod 440 "/etc/sudoers.d/90-$USER_NAME"
    printf '    sudo   : 免密（/etc/sudoers.d/90-%s）\n' "$USER_NAME"

    # ② 再挑 apt 源、装 sudo。state 记到**新用户**名下：他后面跑 ./install.sh
    #    时读到的是同一份（不会测第二遍、也不会换第二次源 —— ADR-0032）。
    WTOOL_STATE="$USER_HOME/.local/state/wtool"
    export WTOOL_STATE
    ENV_MIRROR_SOURCE="container-raw.sh --user"
    export ENV_MIRROR_SOURCE
    if [ -f "$(dirname -- "$0")/install-env.sh" ]; then
        # shellcheck disable=SC1091
        . "$(dirname -- "$0")/install-env.sh"
        if command -v env_apt_ready >/dev/null 2>&1; then
            env_apt_ready || warn "  挑源那一步没成功，继续试装 sudo"
        fi
    else
        warn "  没找到 install-env.sh，直接 apt-get update"
        apt-get update -qq || warn "  apt-get update 没成功，装 sudo 可能会失败"
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends sudo \
            >/dev/null 2>&1 || warn "  装 sudo 失败了 —— 下面这个用户就没有 sudo 用"
    fi
    if command -v sudo >/dev/null 2>&1; then
        printf '    sudo   : %s\n' "$(command -v sudo)"
    else
        warn "    sudo   : 还是没装上（apt 源不通？）"
    fi

    # ③ 家目录里凡是 root 建过的东西，全归它 —— 不然它自己都写不了（上面①的原因）
    chown -R "$USER_NAME:$USER_NAME" "$USER_HOME" 2>/dev/null || true
    printf '    家目录 : %s\n' "$USER_HOME"
fi

cat <<'TIP'

  ────────────────────────────────────────────────────────────
  这个容器里什么都没装 —— 等价于"刚 repo sync 完"。
  接下来四条命令，和你在真机上做的一模一样：

      cd /wtool && ./install.sh     # 准备环境 + 装 wtool 自己（会先让你挑镜像）
      exec $SHELL                   # 让当前 shell 认识 wtool
      wtool sudo-bootstrap          # 系统层：apt 包 + /etc（可能要 sudo、要联网）
      wtool bootstrap               # 用户层：文件、软链、shell 集成（不要 sudo、不联网）

  后两条**别合成一条**：一条要 sudo 要联网，一条永不 sudo 永不联网 ——
  出错时你才分得清该修系统环境还是某个项目。

  第一条会自动认系统、认缺什么包、认要不要接代理 —— 不用你操心。
  它还会**先给国内几个镜像站测速**（各下一个索引、最多 3 秒），画成表让你挑一个，
  然后才装包 —— 官方源在容器里通常比国内镜像慢十几倍。不想挑就 WTOOL_MIRROR=official。
  想看它到底干了什么：./install.sh --dry-run

  ── 以普通用户进去的（--user <名字>）额外知道这几条 ──
      · 你就是那个用户（`whoami` 看一眼）；密码是 **root**
        （`su -` 回 root、`sudo -k` 之后再用，都是它）
      · sudo **免密**：`sudo apt-get update` 直接能跑，不会问你密码
      · 当前目录是它的家目录；工作区在 /wtool（只读挂载）
      · 回 root：`su -`；再回普通用户：`su - <名字>`

  ⚠️ apt 的锁：**别同时开两个都用这个 apt 卷的容器**（`-v wtool-apt-cache:/var/cache/apt`），
     一边在装、另一边 apt 就会报 "Could not get lock ... held by process 0"
     （0 = 占用者在另一个容器里，看不出来是谁）。真撞上了：docker ps 看谁在跑，
     等它跑完；确认没有活着的 apt 之后才清：
       rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
  ────────────────────────────────────────────────────────────

TIP

if [ -n "$USER_NAME" ]; then
    # 以新用户进 shell。`su -` 给的是登录 shell（读它的 ~/.profile / ~/.bashrc），
    # 里面再 `bash -i` —— 和 root 那条路保持同一套语义（stdin 是管道时也读命令，
    # 人工验收脚本就是靠这个喂进来的）。
    say "切到 $USER_NAME（密码 root，sudo 免密）"
    exec su - "$USER_NAME" -c 'exec bash -i'
fi

if command -v bash >/dev/null 2>&1; then
    exec bash -i
else
    exec sh -i
fi
