# wtool 的 bash 补全（由 bootstrap/env.bash 自动 source，不用你手动做）
#
# 候选**全部由引擎自己算**：`wtool _complete <正在敲的词> <已经敲过的词...>`
# —— 别在这个文件里再抄一份命令清单，那样迟早和图例、和分发对不上。
# 引擎里那张表（WTOOL_SUBCOMMANDS）才是唯一的源。
#
# `-o default`：我们给不出候选时（比如某个命令的参数是**路径**）退回 bash 自己的
# 文件名补全 —— 也就是"命令能补命令、路径照旧补路径"。
_wtool_complete() {
    local cur i
    local -a prev
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=()
    for ((i = 1; i < COMP_CWORD; i++)); do
        prev+=("${COMP_WORDS[i]}")
    done
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=($(compgen -W "$(command wtool _complete "$cur" 2>/dev/null)" -- "$cur"))
    else
        COMPREPLY=($(compgen -W "$(command wtool _complete "$cur" "${prev[@]}" 2>/dev/null)" -- "$cur"))
    fi
    return 0
}

complete -o default -o bashdefault -F _wtool_complete wtool
