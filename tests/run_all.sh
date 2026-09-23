#!/bin/sh
# 跑全部测试
#   tests/pairing_test.sh     install/uninstall 的完全配对（33 条）
#   tests/provision_test.sh   sudo-install 层：系统文件 / source / task（24 条）
#   tests/publish_test.sh     publish 的源码包 / 脚本 / 不发布三分支（41 条）
#   tests/table_test.sh       能力表格的格子语义与列对齐（35 条）
#   tests/release_copy_test.sh 从发布包解压出来的工作区（没有 .git 也没有 repo 客户端）（17 条）
#   tests/release_test.sh     pack-release / unpack-release（分卷、dist.json、往返）
#   tests/contract_test.sh    新契约：新标签、两跳软链、执行顺序、check/repair、kill
#   tests/container_test.sh   容器里从零装一遍（需要 docker，见文件头注释）
#   tests/e2e_repo_sync_test.sh  repo sync 全流程（用本地裸仓，较慢）
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)

printf '########## 1/7 pairing（install/uninstall）##########\n'
sh "$here/pairing_test.sh"
printf '\n########## 2/7 sudo-install（系统文件/source/task）##########\n'
sh "$here/provision_test.sh"
printf '\n########## 3/7 publish（源码包/脚本/不发布）##########\n'
sh "$here/publish_test.sh"
printf '\n########## 4/7 table（能力表格）##########\n'
sh "$here/table_test.sh"
printf '\n########## 5/7 release-copy（解压出来的工作区）##########\n'
sh "$here/release_copy_test.sh"
printf '\n########## 6/7 pack-release / unpack-release ##########\n'
sh "$here/release_test.sh"
printf '\n########## 7/7 新契约（标签/两跳/顺序/check/repair/kill）##########\n'
sh "$here/contract_test.sh"
printf '\n全部通过。\n'
