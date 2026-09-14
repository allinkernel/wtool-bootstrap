#!/bin/sh
# 跑全部测试
#   tests/pairing_test.sh     install/uninstall 的完全配对（27 条）
#   tests/provision_test.sh   system-file / source / task（22 条）
#   tests/container_test.sh   容器里从零装一遍（需要 docker，见文件头注释）
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)

printf '########## 1/2 pairing（install/uninstall）##########\n'
sh "$here/pairing_test.sh"
printf '\n########## 2/2 provision（system-file/source/task）##########\n'
sh "$here/provision_test.sh"
printf '\n全部通过。\n'
