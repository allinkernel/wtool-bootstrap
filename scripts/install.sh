#!/bin/sh
# install.sh —— 装 **wtool 自己**。做完就停，然后告诉你下一步跑什么。
#
# 这个脚本只负责一件事：**让 `wtool` 这条命令能用**。
# 它不装任何项目 —— 那是 `wtool bootstrap` 的事。
#
# 完整流程（从头到尾只有两条命令）：
#
#     ./install.sh          # 第 1 步：准备环境 + 装 wtool 自己
#     exec $SHELL           #        让当前 shell 认识 wtool（或重开一个终端）
#     wtool bootstrap       # 第 2 步：装那些不需要你决策的项目
#
# 为什么拆成两步：这两件事的失败原因完全不同。
#   install.sh        失败 = 系统环境问题（缺 python3/git、源连不上）
#   wtool bootstrap   失败 = 某个项目自己的问题
# 混在一条命令里，用户看到一堆输出，分不清该修哪一头。
#
# 发行版的差异在 install-<发行版><版本>.sh 里，主脚本负责探测和派发。
# 加一个新发行版 = 加一个只写"不一样的地方"的小文件，不用动这里。
#
# 用法：
#   ./install.sh              准备环境 + 自举引擎 + 让 wtool 可用
#   ./install.sh --dry-run    只说要做什么
#   WTOOL_MIRROR=mirrors.ustc.edu.cn ./install.sh    顺带换 apt 源
set -eu

# 解析自身真实路径：manifest 的 linkfile 会在工作区根目录放一个指向本脚本的
# 软链，不处理的话"项目目录"会被误判成工作区根目录。
self=$0
while [ -L "$self" ]; do
    target=$(readlink -- "$self")
    case $target in
        /*) self=$target ;;
        *)  self=$(dirname -- "$self")/$target ;;
    esac
done
here=$(cd -- "$(dirname -- "$self")" && pwd)          # = <项目>/scripts
proj=$(cd -- "$here/.." && pwd)                     # = <项目>

say()  { printf 'wtool-install: %s\n' "$*"; }
warn() { printf 'wtool-install: 警告: %s\n' "$*" >&2; }
die()  { printf 'wtool-install: 错误: %s\n' "$*" >&2; exit 1; }

HOME_DIR=${HOME:-/root}
BOOT_DST=${WTOOL_BOOTSTRAP_DST:-$HOME_DIR/.wtool/bootstrap}
DRY_RUN=0
for _a in "$@"; do [ "$_a" = "--dry-run" ] && DRY_RUN=1; done

[ -x "$proj/wtool.sh" ] || die "这里不是 wtool-bootstrap（找不到 wtool.sh）: $proj"

# ==========================================================================
# 被引擎调用时：**只做自举，立刻退出** —— 而且必须在第 0 步之前。
#
# `wtool install bootstrap` 会走到这个脚本（那时 WTOOL_PROJECT_ID 已设好）。
# 这条路径上：
#   · 不能往下走第 0 步 —— 那是"给人用的安装器"该干的事（装 apt 包、
#     试探 git 权限）。引擎正在装东西的时候突然去跑 apt，
#     既莫名其妙又需要 root，测试里直接失败。**这条踩过。**
#   · 不能调 wtool bootstrap —— 会变成
#     install.sh → wtool install bootstrap → install.sh 无限递归。
# ==========================================================================
if [ -n "${WTOOL_PROJECT_ID:-}" ]; then
    say "由引擎调用（项目 ${WTOOL_PROJECT_ID}），只做自举，不再递归"
    _self_dir=$(dirname -- "$self")
    _proj=$(cd -- "$_self_dir/.." && pwd)
    _dst=${WTOOL_BOOTSTRAP_DST:-${HOME:-/root}/.wtool/bootstrap}
    if [ -L "$_dst" ] && [ "$(readlink -f -- "$_dst" 2>/dev/null || true)" = "$_proj" ]; then
        say "  引擎已经指向这里，跳过"
    else
        mkdir -p -- "$(dirname -- "$_dst")"
        ln -sfn -- "$_proj" "$_dst" && say "  已自举到 $_dst"
    fi
    exit 0
fi

# ==========================================================================
# 第 0 步：准备运行环境（发行版不同，做法不同）
#
# wtool 要能跑，最少需要 python3（规划器）和 git（读项目的 HEAD）。
# 最小化的 docker 镜像里这两个都没有，所以要先把它们装上 ——
# 否则下一步自举出来的东西一调用就报"缺少依赖"。
# ==========================================================================
say "第 0 步：准备运行环境"

# 探测发行版。读 /etc/os-release 的 ID + VERSION_ID，
# 拼出 install-<ID><主版本号>.sh（如 ubuntu20）。
_env_profile=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    _id=${ID:-}
    _ver=${VERSION_ID:-}
    _major=${_ver%%.*}
    for _cand in "$here/install-$_id$_major.sh" "$here/install-$_id.sh"; do
        [ -f "$_cand" ] && { _env_profile=$_cand; break; }
    done
    say "  系统：${PRETTY_NAME:-$_id $_ver}"
fi

# env 脚本要用它来试探 git 能不能读仓库
WTOOL_WS_DIR=$(dirname -- "$proj")
export WTOOL_WS_DIR

if [ -n "$_env_profile" ]; then
    say "  用环境脚本：$(basename -- "$_env_profile")"
    if [ "$DRY_RUN" = 1 ]; then
        say "  [dry-run] 会装 python3 / git / ca-certificates / curl（+ ansible）"
    else
        # 先加载共用逻辑，再由 profile 声明"自己不一样的地方"并调用 env_prepare。
        # profile 里不重复写装包换源那些 —— 那些所有发行版都一样。
        [ -f "$here/install-env.sh" ] || die "缺少 $here/install-env.sh"
        # shellcheck disable=SC1091
        . "$here/install-env.sh"
        # shellcheck disable=SC1090
        . "$_env_profile"
    fi
else
    warn "  没有匹配的环境脚本（找过 install-${_id:-?}${_major:-}.sh）"
    warn "  请手动确认这几个命令可用：python3 git curl"
    warn "  缺的话：apt-get install -y --no-install-recommends ca-certificates git python3 curl"
fi

# ==========================================================================
# 第 1 步：自举引擎
#
# 把引擎挂到一个固定位置，这样任何 shell、任何目录下 `wtool` 都能用，
# 不依赖工作区在哪。
# ==========================================================================
say "第 1 步：自举引擎到 $BOOT_DST"
if [ "$DRY_RUN" = 1 ]; then
    say "  [dry-run] 会建软链 $BOOT_DST → $proj"
else
    mkdir -p -- "$(dirname -- "$BOOT_DST")"
    if [ -L "$BOOT_DST" ]; then
        _cur=$(readlink -f -- "$BOOT_DST" 2>/dev/null || true)
        if [ "$_cur" = "$proj" ]; then
            say "  已经指向这里，跳过"
        else
            say "  改指向：$_cur → $proj"
            ln -sfn -- "$proj" "$BOOT_DST"
        fi
    elif [ -e "$BOOT_DST" ]; then
        die "$BOOT_DST 已经存在而且不是软链。先自己处理掉（确认里面没有你要的东西）再重试。"
    else
        ln -sfn -- "$proj" "$BOOT_DST"
        say "  已创建软链"
    fi

    if [ -x "$BOOT_DST/wtool.sh" ]; then
        say "  验证：$("$BOOT_DST/wtool.sh" version 2>/dev/null || echo '调用失败')"
    else
        die "自举后仍然调不到 $BOOT_DST/wtool.sh"
    fi
fi

# ==========================================================================
# 第 2 步：工作区入口软链
#
# 用 `repo sync` 拿到的客户端，这些软链由 repo 按 manifest 的 linkfile 建。
# 但**从发布包解压出来的工作区没有 repo 客户端**，那些软链就不存在——
# 而 README 恰恰让人跑 `./install.sh`。所以这里补上，让两条路拿到的工作区
# 长得一样。（这不算第二份真相：manifest 仍是对 repo 客户端的权威描述，
# 这里只是给没有 repo 的那种情况兜底。）
# ==========================================================================
ws=$(dirname -- "$proj")
say "第 2 步：工作区入口（$ws）"
_ln() {   # <链接名> <相对目标>
    _dest=$ws/$1; _target=$2
    [ "$DRY_RUN" = 1 ] && { say "  [dry-run] $1 -> $_target"; return 0; }
    if [ -L "$_dest" ]; then
        [ "$(readlink -- "$_dest")" = "$_target" ] && return 0
    elif [ -e "$_dest" ]; then
        warn "  $1 已存在且不是软链，跳过（怕覆盖你的东西）"
        return 0
    fi
    [ -e "$ws/$_target" ] || return 0
    ln -sfn -- "$_target" "$_dest" && say "  $1 -> $_target"
}
_ln install.sh   bootstrap/scripts/install.sh
_ln uninstall.sh bootstrap/scripts/uninstall.sh
_ln README.md    wtool-base/README.md
_ln guide.md     wtool-base/guide.md

# ==========================================================================
# 第 3 步：让 `wtool` 这条命令真的能用
#
# 光有引擎文件还不够 —— `wtool` 要出现在 PATH 里，靠的是 bootstrap 项目
# （也就是引擎自己）的环境变量块。所以这里**只装这一个项目**：
#
#   wtool install bootstrap   → 建 ~/.wtool/links/bootstrap、写 env 块、
#                               在用户 rc 里放那一段 loader
#
# 装完这一步，`wtool` 就是一条真命令了。**到此为止**，不再往下装项目。
# ==========================================================================
say "第 3 步：让 wtool 命令可用（只装引擎自己，不装任何项目）"
if [ "$DRY_RUN" = 1 ]; then
    say "  [dry-run] wtool install $proj"
else
    # --force：这一步装的是**引擎自己**，而引擎很可能来自一个开发副本
    # （工作区挂载进来、或有未提交改动）。那种情况下"版本记录不准"，
    # 但不该因此拦住"让 wtool 能用" —— 前者是记账精度，后者是能不能干活。
    #
    # **输出绝不吞掉。** 这里原来是 >/dev/null 2>&1，结果 install 因为
    # 工作区有改动而拒绝时，用户看到的是一片安静，以为装好了 ——
    # 直到敲 wtool 才发现没有，然后完全无从下手。
    # 一个可能"静默失败"的安装步骤，比一个会报错的更坏。
    if ! "$BOOT_DST/wtool.sh" install "$proj" --force; then
        warn "  上面就是失败原因。这一步不成功，wtool 命令还用不了。"
    fi
fi

# ==========================================================================
# 完成。**在这里停下**，把下一步交给用户。
# ==========================================================================
_rc=""
[ -f "$HOME_DIR/.zshrc" ] && _rc="~/.zshrc"
[ -f "$HOME_DIR/.bashrc" ] && _rc="${_rc:+$_rc 和 }~/.bashrc"

cat <<TIP

  ────────────────────────────────────────────────────────────
  装好了。这个脚本只负责让 wtool 能用，**没有装任何项目**。

  当前这个 shell 里 wtool 还看不见（PATH 是启动时定下的），
  让 shell 重新读一次配置：

      exec \$SHELL          # 或者干脆重开一个终端
$([ -n "$_rc" ] && printf '      # 配置写在 %s 里的那一段 loader\n' "$_rc")

  然后：

      wtool                # 看项目表：每个项目支持什么、做到哪一步了
      wtool bootstrap      # 装那些"不需要你决策"的项目

  wtool bootstrap 不会替你做这些决定，需要时才自己跑：
      wtool build    <项目>    自己编（小时级）
      wtool download <项目>    从发布页拿现成的包（分钟级）
      wtool install  <项目>    登记 + 软链 + shell 集成
      wtool uninstall --id <项目>   撤掉
      wtool publish  <项目>    发到项目自己的 release

  想知道每个命令到底做什么，看 README 的第 4 节「这些脚本分别干什么」。
  ────────────────────────────────────────────────────────────

TIP
