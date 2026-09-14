# bootstrap 项目的 env：wtool 的"长期"环境变量（每次开 shell 都会加载）
#
# WTOOL_PROJECT_DIR 由 wtool 块导出 = $HOME/.wtool/links/bootstrap
[[ -n "$WTOOL_PROJECT_DIR" ]] || WTOOL_PROJECT_DIR="$HOME/.wtool/links/bootstrap"

# 探测 OS/架构/并行度，并得到 WTOOL_PREFIX
. "$WTOOL_PROJECT_DIR/lib/wtool_os.sh"
wt_os_detect

# 编译安装前缀：wsw.sh / provision 只准往这里装，删掉即可卸载
export PATH="$WTOOL_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$WTOOL_PREFIX/lib:$WTOOL_PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# 让 wtool 命令可用（wrapper 在本项目 bin/ 下，不往 ~/.local/bin 写东西）
export PATH="$WTOOL_PROJECT_DIR/bin:$PATH"
