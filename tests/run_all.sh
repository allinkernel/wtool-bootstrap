#!/bin/sh
# 跑全部测试
#   tests/pairing_test.sh     install/uninstall 的完全配对（35 条）
#   tests/provision_test.sh   sudo-install 层：系统文件 / source / task（24 条）
#   tests/publish_test.sh     publish-release：打包 / 只上传 / release.json / 拒收下载包（114 条）
#   tests/table_test.sh       能力表格的格子语义与列对齐（43 条）
#   tests/release_copy_test.sh 从发布包解压出来的工作区（没有 .git 也没有 repo 客户端）（17 条）
#   tests/release_test.sh     pack-release / unpack-release / download-release（62 条）
#   tests/contract_test.sh    新契约：新标签、两跳软链、执行顺序、check/repair、kill（69 条）
#   tests/layer_test.sh       layer/<target>/ 那棵 OCI 镜像目录（去打桩的 docker）（14 条）
#   tests/container_test.sh   容器里从零装一遍（需要 docker，见文件头注释）
#   tests/e2e_repo_sync_test.sh  repo sync 全流程（用本地裸仓，较慢）
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)

printf '########## 1/8 pairing（install/uninstall）##########\n'
sh "$here/pairing_test.sh"
printf '\n########## 2/8 sudo-install（系统文件/source/task）##########\n'
sh "$here/provision_test.sh"
printf '\n########## 3/8 publish-release（只上传 + release.json）##########\n'
sh "$here/publish_test.sh"
printf '\n########## 4/8 table（能力表格）##########\n'
sh "$here/table_test.sh"
printf '\n########## 5/8 release-copy（解压出来的工作区）##########\n'
sh "$here/release_copy_test.sh"
printf '\n########## 6/8 pack-release / unpack-release / download-release ##########\n'
sh "$here/release_test.sh"
printf '\n########## 7/8 新契约（标签/两跳/顺序/check/repair/kill）##########\n'
sh "$here/contract_test.sh"
printf '\n########## 8/8 layer/（OCI 镜像目录）##########\n'
sh "$here/layer_test.sh"
printf '\n全部通过。\n'
