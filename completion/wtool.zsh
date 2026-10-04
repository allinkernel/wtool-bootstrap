# wtool 的 zsh 补全（由 bootstrap/env.zsh 自动 source，不用你手动做）
#
# 和 bash 那份一样：候选**全部由引擎自己算**
# （`wtool _complete <正在敲的词> <已经敲过的词...>`），这里不抄命令清单。
#
# 给不出候选时退回 `_files`（路径照旧能补）。

_wtool() {
    local -a cand
    if (( CURRENT == 2 )); then
        cand=(${(f)"$(command wtool _complete "${words[2]}" 2>/dev/null)"})
    else
        cand=(${(f)"$(command wtool _complete "${words[CURRENT]}" ${words[2,CURRENT-1]} 2>/dev/null)"})
    fi
    if (( ${#cand} )); then
        compadd -a cand
    else
        _files
    fi
}

# 有人用纯 zsh（没跑过 compinit）：那就先把它跑起来，否则 compdef 根本不存在，
# Tab 只会去补文件名 —— 用户的要求是"wtool 一生效，Tab 就要能列命令"。
# `compinit -C -u`：跳过安全检查和"同一函数多个候选"的询问（快，且不改用户的东西）。
if ! (( $+functions[compdef] )); then
    autoload -Uz compinit 2>/dev/null && compinit -C -u 2>/dev/null
fi
(( $+functions[compdef] )) && compdef _wtool wtool
