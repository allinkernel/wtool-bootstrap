# bootstrap 项目的 env：wtool 的"长期"环境变量（每次开 shell 都会加载）
#
# WTOOL_PROJECT_DIR 由 wtool 块导出 = $HOME/.wtool/wtool-work-dir/links/bootstrap
[[ -n "$WTOOL_PROJECT_DIR" ]] || WTOOL_PROJECT_DIR="$HOME/.wtool/wtool-work-dir/links/bootstrap"

# 探测 OS/架构/并行度，并得到 WTOOL_PREFIX
. "$WTOOL_PROJECT_DIR/lib/wtool_os.sh"
wt_os_detect

# 编译安装前缀：wsw.sh / provision 只准往这里装，删掉即可卸载
export PATH="$WTOOL_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$WTOOL_PREFIX/lib:$WTOOL_PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# 让 wtool 命令可用（wrapper 在本项目 bin/ 下，不往 ~/.local/bin 写东西）
export PATH="$WTOOL_PROJECT_DIR/bin:$PATH"

# ── Tab 补全（用户 2026-10-04：wtool 生效后 Tab 要立刻列出可选命令）─────────
# 候选由引擎自己算（`wtool _complete`），见 completion/ 下那个文件。
# 放在 PATH 设置之后：补全里要能调到 wtool 命令。
if [ -r "$WTOOL_PROJECT_DIR/completion/wtool.zsh" ]; then
    . "$WTOOL_PROJECT_DIR/completion/wtool.zsh"
fi
