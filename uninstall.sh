#!/bin/sh
# wtool 项目存根（由 wtool.sh scaffold 生成，请勿手改）
#
# 它只做一件事：找到 wtool-bootstrap 并把活儿交给它。
# 复制成 install.sh / uninstall.sh 即可，靠自身文件名判断子命令。
set -eu

# 解析自身真实路径。
# ⚠️ 必须处理软链：manifest 的 linkfile 会在仓库根目录放一个指向本脚本的软链，
#    若直接用 "$0" 的目录，"项目目录"会被误判成"仓库根目录"，于是找不到引擎。
self=$0
while [ -L "$self" ]; do
    target=$(readlink -- "$self")
    case $target in
        /*) self=$target ;;
        *)  self=$(dirname -- "$self")/$target ;;
    esac
done
here=$(cd -- "$(dirname -- "$self")" && pwd)

case $(basename -- "$0") in
    install.sh)   cmd=install ;;
    uninstall.sh) cmd=uninstall ;;
    *)            cmd=${1:-}; [ $# -gt 0 ] && shift ;;
esac
[ -n "${cmd:-}" ] || { echo "用法: $0 [install|uninstall]" >&2; exit 2; }

# bootstrap 定位顺序：
#   1. $WTOOL_BOOTSTRAP
#   2. 从本项目向上 4 层找 bootstrap/ 或 wtool-bootstrap/
#      （仓库根目录的软链入口走这条：$here 是 <root>/bootstrap，上一级是 <root>）
#   3. ~/.wtool/bootstrap
boot=${WTOOL_BOOTSTRAP:-}
if [ -z "$boot" ] || [ ! -x "$boot/wtool.sh" ]; then
    d=$here
    i=0
    while [ $i -lt 4 ]; do
        d=$(dirname -- "$d")
        i=$((i + 1))
        for cand in "$d/bootstrap" "$d/wtool-bootstrap"; do
            if [ -x "$cand/wtool.sh" ]; then boot=$cand; break 2; fi
        done
    done
fi
[ -n "$boot" ] || boot=$HOME/.wtool/bootstrap

if [ ! -x "$boot/wtool.sh" ]; then
    cat >&2 <<'EOF'
找不到 wtool-bootstrap。请任选其一：
  git clone <bootstrap-repo> ~/.wtool/bootstrap
  export WTOOL_BOOTSTRAP=/path/to/wtool-bootstrap
EOF
    exit 1
fi

exec "$boot/wtool.sh" "$cmd" "$here" "$@"
