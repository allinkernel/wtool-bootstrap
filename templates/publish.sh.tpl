#!/bin/sh
# publish.sh —— @PROJECT_ID@ 的发布步骤
#
# 只有"源码包不够用"的项目才需要它：需要编译产物、需要分卷、
# 需要起 docker 之类的。纯配置类项目请**不要**提供这个脚本 ——
# 引擎默认会把源码打成包推到本仓 release，够用了。
#
# 由 `wtool publish @PROJECT_ID@` 调用，引擎保证的环境变量：
#   WTOOL_PUBLISH_PROJECT   项目 id
#   WTOOL_PUBLISH_ROOT      项目目录
#   WTOOL_PUBLISH_WS        工作区根目录
#   WTOOL_PUBLISH_REPO      目标仓 owner/repo
#   WTOOL_PUBLISH_TAG       release tag
#   WTOOL_PUBLISH_OUT       产物目录 —— 把要上传的文件放这里
#   WTOOL_PUBLISH_DATE      YYYY-MM-DD
#   WTOOL_PUBLISH_FORCE     1 表示调用方加了 --force
#
# 契约很简单：**把文件放进 $WTOOL_PUBLISH_OUT**，建 release 和上传由引擎做。
# 这样 gh 的调用、tag 规则、权限检查只有一份实现，脚本也能单独 dry-run。
#
# 想要和引擎打的一样的源码包（第一层 wtool/，解压后路径和 repo sync 一致），
# 可以复用现成命令，见 guide.md「发布」一节。
set -eu

say() { printf '%s: %s\n' "@PROJECT_ID@" "$*"; }

say "产出到 $WTOOL_PUBLISH_OUT"

# TODO: 在这里生成要发布的文件，例如：
#   tar -C "$WTOOL_PUBLISH_WS" --transform='s|^|wtool/|S' -cf - "$WTOOL_PUBLISH_PROJECT" \
#       | zstd -T0 -3 -o "$WTOOL_PUBLISH_OUT/@PROJECT_ID@-$WTOOL_PUBLISH_DATE.tar.zst"
#
# 注意那个 S：不加的话 tar 会连**符号链接的指向**一起改写，包里的相对软链会全变断链。

say "完成"
