#!/bin/sh
# download.sh —— @PROJECT_ID@ 从发布页拿现成的包，代替自己编
#
# 由 `wtool download @PROJECT_ID@` 调用。和 scripts/build.sh 是**一对**：
#
#   build.sh     自己编/自己下，把产物放到最终位置
#   download.sh  从 GitHub Release 拿别人编好的，解到**同样的位置**
#
# 两条路必须等价 —— 之后的 `wtool install` 完全不关心产物是编出来的
# 还是下下来的（见 guide.md「产物契约」）。
#
# 引擎保证的环境变量：
#   WTOOL_PROJECT_ID / WTOOL_PROJECT_DIR / WTOOL_PROJECT_ROOT
#   WTOOL_ARTIFACTS   产物清单的文件路径 —— 把产出的每条路径写进去
#                     格式: kind<TAB>相对$HOME的路径<TAB>来源<TAB>时间
#   WTOOL_STATE_DIR   本项目的状态目录
#   WTOOL_OS_ID / WTOOL_OS_VERSION / WTOOL_OS_CODENAME / WTOOL_ARCH
#
# 选哪个包：不要自己按发行版名字硬匹配。用引擎提供的 release_mgr.py，
# 它会读 scripts/release.json，按"glibc ≤ 本机"选最新的那个
# （glibc 单向兼容：老环境编的能在新环境跑，反过来不行）。
set -eu

PROJECT_ID=${WTOOL_PROJECT_ID:-@PROJECT_ID@}
ARTIFACTS=${WTOOL_ARTIFACTS:-${WTOOL_STATE_DIR:-$HOME/.local/state/wtool/$PROJECT_ID}/artifacts.tsv}

say() { printf '%s: %s\n' "$PROJECT_ID" "$*"; }

say "开始下载"
mkdir -p -- "$(dirname -- "$ARTIFACTS")"

# TODO: 在这里下载并解包，然后把产物路径写进 $ARTIFACTS，例如：
#   mkdir -p "$HOME/.local/bin"
#   tar -xf "$pkg" -C "$HOME"
#   printf 'payload\t.local/bin/foo\t%s\tdownload\n' "$(date -Is)" >> "$ARTIFACTS"

say "下载完成"
