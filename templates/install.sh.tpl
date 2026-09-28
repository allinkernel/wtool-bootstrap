#!/bin/sh
# install.sh —— @PROJECT_ID@ 自己的安装步骤
#
# 由 `wtool install @PROJECT_ID@` 调用（§4.2 的执行顺序，编号跟契约一致）：
#   ① 引擎基建：中转链接 ~/.wtool/wtool-work-dir/links/<id> + 本项目的 env 块
#   ① 这个脚本：output/ → ~/.wtool/usr（影子 HOME）
#   ② wtool.xml 的 <link>：~/.wtool/… → $HOME/…
# 也就是说**两件 ① 都比 ② 早**，而本脚本在另一件 ① 之后 ——
# ②建的软链指向本脚本铺出来的东西，反了就是先建一堆悬空链接。
# 所以这里可以直接用稳定地址（它此刻已经建好了）：
#   $HOME/.wtool/wtool-work-dir/links/@PROJECT_ID@   ->  本项目目录
#
# 只有"通用机制做不到的事"才写在这里。如果 wtool.xml 的 <link>/<zshrc>
# 已经够了，就**不要**提供这个文件——把它留着当摆设，
# 只会让 `wtool install` 多跑一遍空转。
#
# 约定：
#   * 产物落在 $WTOOL_PREFIX（= ~/.wtool/usr）下面，$HOME 里只留软链
#   * stdin 是 /dev/null —— 不要写交互式提问
#   * 要可重入
#   * 卸载走 `install.sh --uninstall` 和 `wtool uninstall`，别在这里做不可逆的事
set -eu

say() { printf '%s: %s\n' "@PROJECT_ID@" "$*"; }
link_dir="$HOME/.wtool/wtool-work-dir/links/@PROJECT_ID@"

say "安装开始"

# TODO: 在这里写 wtool.xml 表达不了的安装步骤：
#   mkdir -p "$WTOOL_PREFIX/bin"
#   cp -f output/bin/foo "$WTOOL_PREFIX/bin/foo"

say "安装完成"
