#!/bin/sh
# build.sh —— @PROJECT_ID@ 的构建步骤
#
# 由 `wtool build @PROJECT_ID@` 调用（人工也可以直接跑）。
#
# 引擎保证的环境变量：
#   WTOOL_PROJECT_ID / WTOOL_PROJECT_DIR / WTOOL_PROJECT_ROOT
#   WTOOL_WORKSPACE   整个 wtool 集合的根目录
#   WTOOL_PREFIX      编译安装前缀（默认 ~/.wtool/usr）
#   WTOOL_JOBS        并行任务数（nproc）
#   WTOOL_OS_ID / WTOOL_OS_VERSION / WTOOL_OS_CODENAME / WTOOL_OS_LIKE
#   WTOOL_ARCH
#
# 约定：
#   * stdin 是 /dev/null —— 不要写交互式提问，没人应答
#   * 要可重入：跑第二遍不能炸
#   * 产物路径要能说清楚：publish.sh 和 install.sh 都要用
set -eu

say() { printf '%s: %s\n' "@PROJECT_ID@" "$*"; }

say "构建开始（-j${WTOOL_JOBS:-1}）"

# TODO: 在这里写构建步骤。
#   常见的几种：
#     编译源码     cmake -S . -B build -DCMAKE_INSTALL_PREFIX="$WTOOL_PREFIX"
#                  cmake --build build -j"$WTOOL_JOBS" && cmake --install build
#     下载二进制   curl -fL -o /tmp/x.tar.gz <url> && tar -xf /tmp/x.tar.gz -C "$WTOOL_PREFIX"
#     生成配置     ./scripts/gen.sh > "$WTOOL_PROJECT_DIR/generated.conf"
#
#   产物请落在 $WTOOL_PREFIX 或本项目目录下，别写系统路径。

say "构建完成"
