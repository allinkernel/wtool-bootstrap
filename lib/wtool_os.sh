#!/bin/sh
# wtool 环境探测 —— 引擎和项目 env 共用（POSIX，sh/bash/zsh 都能 source）
#
# 产出（调用 wt_os_detect 之后）：
#   WTOOL_PREFIX        编译安装前缀，默认 $HOME/.wtool/usr
#   WTOOL_OS_ID         ubuntu / debian / rocky / centos / rhel / fedora / ...
#   WTOOL_OS_VERSION    24.04 / 9.4 / ...
#   WTOOL_OS_CODENAME   noble / bookworm / ...（可能为空）
#   WTOOL_OS_LIKE       debian / "rhel centos fedora" / ...
#   WTOOL_ARCH          x86_64 / aarch64 / ...
#   WTOOL_JOBS          nproc
#
# 约定：只计算、不打印、不写文件；可重复调用（幂等）。

wt_os_detect() {
    : "${WTOOL_PREFIX:=$HOME/.wtool/usr}"
    WTOOL_OS_ID=""
    WTOOL_OS_VERSION=""
    WTOOL_OS_CODENAME=""
    WTOOL_OS_LIKE=""

    if [ -r /etc/os-release ]; then
        while IFS='=' read -r _k _v; do
            case $_v in
                \"*\") _v=${_v#\"}; _v=${_v%\"} ;;
            esac
            case $_k in
                ID)               WTOOL_OS_ID=$_v ;;
                VERSION_ID)       WTOOL_OS_VERSION=$_v ;;
                VERSION_CODENAME) WTOOL_OS_CODENAME=$_v ;;
                ID_LIKE)          WTOOL_OS_LIKE=$_v ;;
            esac
        done < /etc/os-release
    fi

    [ -n "$WTOOL_OS_ID" ] || WTOOL_OS_ID=$(uname -s 2>/dev/null | tr 'A-Z' 'a-z')
    WTOOL_ARCH=$(uname -m 2>/dev/null || echo unknown)
    WTOOL_JOBS=$(nproc 2>/dev/null || echo 1)

    export WTOOL_PREFIX WTOOL_OS_ID WTOOL_OS_VERSION WTOOL_OS_CODENAME \
           WTOOL_OS_LIKE WTOOL_ARCH WTOOL_JOBS
}
