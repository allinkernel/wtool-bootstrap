#!/bin/sh
# 跑全部测试
#
# ⚠️ 下面括号里的条数**以跑出来的 PASS 行为准** —— 这行注释是手写的，会过期；
#    数字对不上时先数 PASS 行，再回来改这里（括号里就是 2026-10-04 的实测真值）。
#   tests/pairing_test.sh     install/uninstall 的完全配对（35 条）
#   tests/provision_test.sh   sudo-install 层：系统文件 / source / task（40 条）
#   tests/publish_test.sh     publish-release：打包 / 只上传 / release.json / 拒收下载包（124 条）
#   tests/table_test.sh       能力表格的格子语义与列对齐（94 条）
#   tests/release_copy_test.sh 从发布包解压出来的工作区（没有 .git 也没有 repo 客户端）（17 条）
#   tests/release_test.sh     pack-release / unpack-release / download-release（71 条）
#   tests/contract_test.sh    新契约：新标签、两跳软链、执行顺序、check/repair、kill、
#                             --dry-run 不跑项目脚本、uninstall 认 id 也跑项目脚本、
#                             补全表与参数解析对得上、--id 老写法指路、wtool move、
#                             改名残渣 check 报得出来（250 条）
#   tests/layer_test.sh       __layer/<target>/ 那棵 OCI 镜像目录（打桩 docker/skopeo，不联网）（50 条）
#   tests/docker_build_test.sh kind=docker 的引擎驱动构建（打桩 docker，不联网）（101 条）
#   tests/install_env_test.sh install.sh 第 0 步：镜像测速 / 挑源 / 换源与退路（打桩，不联网）（67 条）
#                             —— 十组共 849 条（2026-10-04 实测）
#   tests/docker_build_real.sh 同一件事的**真 docker** 冒烟测试（人工跑，见文件头）
#   tests/container_test.sh   容器里从零装一遍（需要 docker，见文件头注释）
#   tests/container_acceptance.sh  人工总验收：把它喂给容器里的 container-raw.sh（见文件头）
#   tests/e2e_repo_sync_test.sh  repo sync 全流程（用本地裸仓，较慢）
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)

printf '########## 1/10 pairing（install/uninstall）##########\n'
sh "$here/pairing_test.sh"
printf '\n########## 2/10 sudo-install（系统文件/source/task）##########\n'
sh "$here/provision_test.sh"
printf '\n########## 3/10 publish-release（只上传 + release.json）##########\n'
sh "$here/publish_test.sh"
printf '\n########## 4/10 table（能力表格）##########\n'
sh "$here/table_test.sh"
printf '\n########## 5/10 release-copy（解压出来的工作区）##########\n'
sh "$here/release_copy_test.sh"
printf '\n########## 6/10 pack-release / unpack-release / download-release ##########\n'
sh "$here/release_test.sh"
printf '\n########## 7/10 新契约（标签/两跳/顺序/check/repair/kill）##########\n'
sh "$here/contract_test.sh"
printf '\n########## 8/10 __layer/（OCI 镜像目录）##########\n'
sh "$here/layer_test.sh"
printf '\n########## 9/10 引擎驱动容器构建（kind=docker）##########\n'
sh "$here/docker_build_test.sh"
printf '\n########## 10/10 install.sh 第 0 步（镜像测速 / 挑源 / 换源与退路）##########\n'
sh "$here/install_env_test.sh"
printf '\n全部通过。\n'
