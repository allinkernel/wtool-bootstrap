# bootstrap 项目的 env（bash 版）：与 env.zsh 等价
# WTOOL_PROJECT_DIR 由 wtool 块导出 = $HOME/.wtool/links/bootstrap
[ -n "$WTOOL_PROJECT_DIR" ] || WTOOL_PROJECT_DIR="$HOME/.wtool/links/bootstrap"

. "$WTOOL_PROJECT_DIR/lib/wtool_os.sh"
wt_os_detect

export PATH="$WTOOL_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$WTOOL_PREFIX/lib:$WTOOL_PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

export PATH="$WTOOL_PROJECT_DIR/bin:$PATH"
