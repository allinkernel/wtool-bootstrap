#!/bin/sh
# install-ubuntu22.sh —— Ubuntu 22.04 (jammy)
#
# 这个文件**只写不一样的地方**。装包、换源、自举那些所有发行版都一样的
# 逻辑在 install-env.sh 里，install.sh 探测完系统会把它 source 进来。
#
# 22.04 起有 ansible-core，优先用它（更小）；没有就退回 ansible。
set -eu
ENV_NAME="Ubuntu 22.04 (jammy)"
# ansible 的包名逐版本试。写死一个名字在别的版本上就是
# "Unable to locate package"，而用户得自己去猜 —— 源都配好了，我们自己试就行。
ENV_ANSIBLE="ansible-core ansible"
ENV_EXTRA_PKGS=""
env_prepare
