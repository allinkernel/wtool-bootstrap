#!/bin/sh
# bootstrap 的卸载器 —— 撤销 ./install.sh 做的事。
#
# 只做可逆的事：
#   1. 让 wtool 把各项目的 install 逆着做一遍（wtool uninstall）
#   2. 删掉引擎自举软链 ~/.wtool/bootstrap
#
# 不碰系统依赖（apt 装的东西可能别的软件也在用），也不删工作区本身。
#
# 用法：
#   ./uninstall.sh [--dry-run] [--no-script]
set -eu

self=$0
while [ -L "$self" ]; do
    target=$(readlink -- "$self")
    case $target in
        /*) self=$target ;;
        *)  self=$(dirname -- "$self")/$target ;;
    esac
done
here=$(cd -- "$(dirname -- "$self")" && pwd)

say() { printf 'wtool-bootstrap: %s\n' "$*"; }
die() { printf 'wtool-bootstrap: 错误: %s\n' "$*" >&2; exit 1; }

HOME_DIR=${HOME:-/root}
BOOT_DST=${WTOOL_BOOTSTRAP_DST:-$HOME_DIR/.wtool/bootstrap}
DRY=0
NO_SCRIPT=0
for arg in "$@"; do
    case $arg in
        --dry-run)   DRY=1 ;;
        --no-script) NO_SCRIPT=1 ;;
        --force)     ;;   # 兼容：卸载本来就是幂等的
        -*)          die "未知参数: $arg" ;;
    esac
done

# 引擎调用时（wtool uninstall bootstrap）不做工作区级别的撤销，只收自举软链
# —— 和 install.sh 对称，避免递归。
if [ -n "${WTOOL_PROJECT_ID:-}" ]; then
    say "由引擎调用（项目 ${WTOOL_PROJECT_ID}），只收自举软链"
    if [ -L "$BOOT_DST" ]; then
        [ "$DRY" = 1 ] || rm -f -- "$BOOT_DST"
        say "  已删除 $BOOT_DST"
    fi
    exit 0
fi

if [ -x "$here/wtool.sh" ]; then
    say "让 wtool 逆着卸载各个项目"
    _ws=$(dirname -- "$here")
    python3 "$here/lib/wtool_plan.py" list-projects --root "$_ws" 2>/dev/null |
    while IFS='	' read -r _prio _pid _path; do
        [ -n "${_path:-}" ] || continue
        _extra=""
        [ "$NO_SCRIPT" = 1 ] && _extra="--no-script"
        if [ "$DRY" = 1 ]; then
            "$here/wtool.sh" uninstall "$_path" --dry-run $_extra || true
        else
            "$here/wtool.sh" uninstall "$_path" --force $_extra || true
        fi
    done
fi

say "收掉引擎自举软链"
if [ -L "$BOOT_DST" ]; then
    [ "$DRY" = 1 ] || rm -f -- "$BOOT_DST"
    say "  已删除 $BOOT_DST"
else
    say "  $BOOT_DST 不在，跳过"
fi

say "卸载完成"
say ""
say "注意："
say "  * 系统依赖（apt 装的）没有动 —— 可能别的软件也在用，自己看着删"
say "  * 工作区目录本身没有删"
say "  * 项目自己的 install.sh 往 \$HOME 放的东西，由它自己负责收拾"
