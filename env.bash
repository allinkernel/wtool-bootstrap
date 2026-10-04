# bootstrap 项目的 env（bash 版）：与 env.zsh 等价
# WTOOL_PROJECT_DIR 由 wtool 块导出 = $HOME/.wtool/wtool-work-dir/links/bootstrap
[ -n "$WTOOL_PROJECT_DIR" ] || WTOOL_PROJECT_DIR="$HOME/.wtool/wtool-work-dir/links/bootstrap"

. "$WTOOL_PROJECT_DIR/lib/wtool_os.sh"
wt_os_detect

export PATH="$WTOOL_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$WTOOL_PREFIX/lib:$WTOOL_PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

export PATH="$WTOOL_PROJECT_DIR/bin:$PATH"

# ── Tab 补全（用户 2026-10-04：wtool 生效后 Tab 要立刻列出可选命令）─────────
# 候选由引擎自己算（`wtool _complete`），见 completion/ 下那个文件。
# 放在 PATH 设置之后：补全里要能调到 wtool 命令。
if [ -r "$WTOOL_PROJECT_DIR/completion/wtool.bash" ]; then
    . "$WTOOL_PROJECT_DIR/completion/wtool.bash"
fi
