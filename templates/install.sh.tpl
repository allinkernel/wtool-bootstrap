#!/bin/sh
# install.sh —— @PROJECT_ID@ 自己的安装步骤
#
# 由 `wtool install @PROJECT_ID@` 在**通用机制之后**调用：
# wtool 先按 wtool.xml 把软链和 shell 托管块铺好，再跑这个脚本。
# 所以这里可以直接用稳定地址：
#   $HOME/.wtool/links/@PROJECT_ID@   ->  本项目目录
#
# 只有"通用机制做不到的事"才写在这里。如果 wtool.xml 的 <link>/<env>
# 已经够了，就**不要**提供这个文件——把这个脚本留着当摆设，
# 只会让 `wtool install` 多跑一遍空转。
#
# 约定：
#   * stdin 是 /dev/null —— 不要写交互式提问
#   * 要可重入
#   * 卸载要走 `wtool uninstall`，别在这里做不可逆的事
set -eu

say() { printf '%s: %s\n' "@PROJECT_ID@" "$*"; }
link_dir="$HOME/.wtool/links/@PROJECT_ID@"

say "安装开始"

# TODO: 在这里写 wtool.xml 表达不了的安装步骤。

say "安装完成"
