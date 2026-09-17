#!/bin/sh
# install-env.sh —— 给 wtool 准备运行环境的**共用逻辑**。
#
# 不单独执行，由 install.sh 选中的发行版脚本 source 进来。
# 各发行版脚本只写"自己不一样的地方"（见 install-ubuntu20.sh 那种），
# 装包、挑镜像、自举引擎这些所有发行版都一样的部分都在这里。
#
# 各 profile 要设置的变量：
#   ENV_NAME          发行版名字，给人看的（"Ubuntu 20.04 (focal)"）
#   ENV_ANSIBLE       这个版本上 ansible 的**包名**（见下面的说明）
#   ENV_EXTRA_PKGS    额外的包（可空）
#   ENV_MIRROR        可选的镜像主机名；留空就用系统自带的源
#
# 为什么 python3 之外还要装这些：
#   git           引擎要读各项目的 HEAD（发布、版本检查都靠它）
#   ca-certificates  HTTPS 必需；缺了 apt 换 https 源会证书报错
#   curl           download.sh 从发布页取包用的就是它（**不依赖 gh**）
#   ansible        os/ubuntu 用它装系统包（provision 那一步）
set -eu

env_say()  { printf 'wtool-install: %s\n' "$*"; }
env_warn() { printf 'wtool-install: 警告: %s\n' "$*" >&2; }

# root 下不能带 sudo —— 最小化容器里根本没有 sudo，
# 写了的话用户照着复制会得到 "sudo: command not found"
env_priv() {
    if [ "$(id -u 2>/dev/null || echo 0)" = 0 ]; then printf ''
    elif command -v sudo >/dev/null 2>&1; then printf 'sudo '
    else printf ''
    fi
}

env_need_root() {
    [ "$(id -u 2>/dev/null || echo 1)" = 0 ] && return 0
    command -v sudo >/dev/null 2>&1 && return 0
    env_warn "当前既不是 root 也没有 sudo，装包这一步会失败"
    env_warn "  手动执行时加 sudo，或者用 root 跑"
    return 1
}

# 换源：可选。不设 ENV_MIRROR 就完全不动系统源。
#
# 默认**不动**是有道理的：能连通官方源的机器不该被我们改掉配置，
# 而且改源是个有副作用的动作，用户没要求就不该做。
# 需要的时候（比如容器里走代理 502）用环境变量打开：
#     WTOOL_MIRROR=mirrors.ustc.edu.cn ./install.sh
env_use_mirror() {
    [ -n "${ENV_MIRROR:-}" ] || return 0
    env_say "换 apt 源 → $ENV_MIRROR"
    . /etc/os-release 2>/dev/null || true
    [ -n "${VERSION_CODENAME:-}" ] || { env_warn "读不出 VERSION_CODENAME，跳过换源"; return 0; }

    mkdir -p /etc/apt/sources.list.d
    # deb822（.sources）在 apt 1.1 就有了，20.04 的 apt 2.0 也认。
    # 曾经误以为 focal 不认，走了弯路 —— 见 harness/notes/03-hazards.md。
    cat > /etc/apt/sources.list.d/wtool-mirror.sources <<EOF
Types: deb
URIs: http://$ENV_MIRROR/ubuntu/
Suites: $VERSION_CODENAME $VERSION_CODENAME-updates $VERSION_CODENAME-backports $VERSION_CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    # 原来的源文件要清掉，否则它还指着官方源，换源等于没换。
    # 20.04 是 /etc/apt/sources.list，24.04 是 sources.list.d/ubuntu.sources —— 两种都清。
    rm -f /etc/apt/sources.list 2>/dev/null || true
    for _f in /etc/apt/sources.list.d/*; do
        case $_f in
            */wtool-mirror.sources) ;;
            *) rm -f -- "$_f" 2>/dev/null || true ;;
        esac
    done
}

# 挑一个能用的 apt 源。先试系统自带的，实在不行再换国内镜像。
env_apt_ready() {
    env_say "检查 apt 源"
    if apt-get update -qq >/dev/null 2>&1; then
        env_say "  系统自带的源可用"
        return 0
    fi
    _m=${ENV_MIRROR:-mirrors.ustc.edu.cn}
    env_warn "  系统自带的源不可用，换 $m"
    ENV_MIRROR=$_m
    env_use_mirror
    apt-get update -qq >/dev/null 2>&1 || {
        env_warn "  换源后还是不行 —— 网络问题，下面的装包大概率会失败"
        return 0
    }
    env_say "  换源后可用"
}

# 装一个包，**按候选名依次试**。
#
# 为什么需要"依次试"：包名在发行版之间会变。同一个东西：
#   Ubuntu 22.04+   ansible-core
#   Ubuntu 20.04    只有 ansible（2.9），**没有 ansible-core**
# 写死一个名字，在另一种系统上就是 "Unable to locate package"，
# 然后用户得自己去猜该装什么 —— 而这时候源已经配好了，我们完全有能力自己试出来。
env_install_first() {
    _desc=$1; shift
    for _p in "$@"; do
        # shellcheck disable=SC2086
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
               --no-install-recommends $_p >/dev/null 2>&1; then
            env_say "  $_desc ✓（包名 $_p）"
            return 0
        fi
    done
    env_warn "  $_desc 装不上（试过: $*）"
    return 1
}

# ── 主流程 ──
env_prepare() {
    env_say "系统：$ENV_NAME"
    env_need_root || true
    _p=$(env_priv)

    command -v apt-get >/dev/null 2>&1 \
        || { env_warn "这个脚本只处理 apt 系发行版；请手动装 python3 / git / curl / ca-certificates"; return 1; }

    env_apt_ready

    # 基础四件套：缺任何一个 wtool 都跑不起来或跑不全
    env_say "装 wtool 需要的运行环境"
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        ca-certificates git python3 curl ${ENV_EXTRA_PKGS:-} >/dev/null 2>&1 \
        && env_say "  ca-certificates git python3 curl ✓" \
        || env_warn "  基础包没全装上，看下面缺什么"

    # ansible 是可选的：只有 os/ubuntu 的 provision 用它。
    # 装不上不影响 wtool 本体，所以失败只警告。
    env_install_first "ansible（os/ubuntu 装系统包用）" $ENV_ANSIBLE || true

    # 装完复查，缺什么明说 —— 不要让用户在后面某一步才撞上
    _miss=""
    for c in python3 git; do command -v "$c" >/dev/null 2>&1 || _miss="$_miss $c"; done
    if [ -n "$_miss" ]; then
        env_warn "还缺:$_miss —— 请手动装：${_p}apt-get install -y$_miss"
        return 1
    fi
    # 最后一件：让 git 接受这个仓库。
    #
    # 容器里以 root 访问宿主目录时，git 会以 "dubious ownership" 拒绝工作。
    # 这是**环境**问题不是项目问题，所以在这里解决掉 ——
    # 否则用户会在下一步撞上一句看起来和"装 wtool"毫不相干的 git 报错，
    # 然后去怀疑网络、怀疑仓库坏了。
    # **必须放在装 git 之后**：git 还没装上时这条命令根本不存在。
    env_git_ownership

    env_say "运行环境就绪"
}

# 让 git 认这个仓库（只在以 root 访问别人的仓库时才需要）
env_git_ownership() {
    [ -n "${WTOOL_WS_DIR:-}" ] || return 0
    command -v git >/dev/null 2>&1 || return 0
    [ "$(id -u 2>/dev/null || echo 1)" = 0 ] || return 0
    # 读一次试试：能读就什么都不用做
    if git -C "$WTOOL_WS_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        return 0
    fi
    git config --global --add safe.directory '*' 2>/dev/null || true
    env_say "  已允许 git 使用挂载进来的仓库（容器里以 root 访问宿主目录时要这一步）"
}
