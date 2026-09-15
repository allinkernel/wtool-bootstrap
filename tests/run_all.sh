#!/bin/sh
# 跑全部测试
#   tests/pairing_test.sh     install/uninstall 的完全配对（27 条）
#   tests/provision_test.sh   system-file / source / task（24 条）
#   tests/publish_test.sh     publish 的源码包 / 脚本 / 不发布三分支（20 条）
#   tests/table_test.sh       能力表格的格子语义与列对齐
#   tests/release_copy_test.sh 从发布包解压出来的工作区（没有 .git 也没有 repo 客户端）
#   tests/container_test.sh   容器里从零装一遍（需要 docker，见文件头注释）
#   tests/e2e_repo_sync_test.sh  repo sync 全流程（用本地裸仓，较慢）
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)

printf '########## 1/5 pairing（install/uninstall）##########\n'
sh "$here/pairing_test.sh"
printf '\n########## 2/5 provision（system-file/source/task）##########\n'
sh "$here/provision_test.sh"
printf '\n########## 3/5 publish（源码包/脚本/不发布）##########\n'
sh "$here/publish_test.sh"
printf '\n########## 4/5 table（能力表格）##########\n'
sh "$here/table_test.sh"
printf '\n########## 5/5 release-copy（解压出来的工作区）##########\n'
sh "$here/release_copy_test.sh"
printf '\n全部通过。\n'
