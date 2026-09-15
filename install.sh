#!/bin/sh
# bootstrap 的安装器 —— 也是「没有 git clone 时」的入口。
#
# 两种调用方式，区别很重要：
#
#   1. 人工直接跑（从发布包解压出工作区之后，入口就是它）
#        ./install.sh                # 自举引擎 + 把整个集合装好
#        ./install.sh --with-system  # 顺带改系统文件（换源等）
#      这条路上它会：把引擎挂到 ~/.wtool/bootstrap，然后交给 wtool bootstrap
#      按 priority 依次 provision + install 所有项目。
#
#   2. 引擎调用（`wtool install bootstrap` 走到本项目时）
#        WTOOL_PROJECT_ID 已经被引擎设好
#       **这时只做引擎自举那一小步**——绝不能再调 wtool bootstrap，
#      否则就是 install.sh → wtool bootstrap → wtool install bootstrap
#       → install.sh 的无限递归。
#
# 用法：
#   ./install.sh [--with-system] [--no-system] [--install-only] [--dry-run] [--force]
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
here=$(cd -- "$(dirname -- "$self")" && pwd)

say()  { printf 'wtool-bootstrap: %s\n' "$*"; }
warn() { printf 'wtool-bootstrap: 警告: %s\n' "$*" >&2; }
die()  { printf 'wtool-bootstrap: 错误: %s\n' "$*" >&2; exit 1; }

HOME_DIR=${HOME:-/root}
BOOT_DST=${WTOOL_BOOTSTRAP_DST:-$HOME_DIR/.wtool/bootstrap}

[ -x "$here/wtool.sh" ] || die "这里不是 wtool-bootstrap（找不到 wtool.sh）: $here"

# --------------------------------------------------------------------------
# 第一步：自举。把引擎挂到一个固定位置，这样任何 shell、任何目录下
# `wtool` 都能用，不依赖工作区在哪。
# --------------------------------------------------------------------------
say "引擎自举到 $BOOT_DST"
mkdir -p -- "$(dirname -- "$BOOT_DST")"
if [ -L "$BOOT_DST" ]; then
    _cur=$(readlink -f -- "$BOOT_DST" 2>/dev/null || true)
    if [ "$_cur" = "$here" ]; then
        say "  已经指向这里，跳过"
    else
        say "  改指向：$_cur → $here"
        ln -sfn -- "$here" "$BOOT_DST"
    fi
elif [ -e "$BOOT_DST" ]; then
    die "$BOOT_DST 已经存在而且不是软链。先自己处理掉（确认里面没有你要的东西）再重试。"
else
    ln -sfn -- "$here" "$BOOT_DST"
    say "  已创建软链"
fi

if [ -x "$BOOT_DST/wtool.sh" ]; then
    say "  验证：$("$BOOT_DST/wtool.sh" version 2>/dev/null || echo '调用失败')"
else
    die "自举后仍然调不到 $BOOT_DST/wtool.sh"
fi

# --------------------------------------------------------------------------
# 第二步：被引擎调用时到此为止
# --------------------------------------------------------------------------
if [ -n "${WTOOL_PROJECT_ID:-}" ]; then
    say "由引擎调用（项目 ${WTOOL_PROJECT_ID}），只做自举，不再递归"
    exit 0
fi

# --------------------------------------------------------------------------
# 第三步：人工调用 —— 让 wtool 把整个工作区装好
# --------------------------------------------------------------------------
say "交给 wtool bootstrap（按 priority 依次 provision + install 所有项目）"
exec "$BOOT_DST/wtool.sh" bootstrap "$@"
