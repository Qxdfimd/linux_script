#!/usr/bin/env bash

# 确保脚本以 bash 运行

# 提示输入主机名
echo "请输入hostname："
read -r hostname

# 设置主机名函数
set_hostname() {
    # 优先使用 hostnamectl（systemd）
    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$hostname"
        echo "已通过 hostnamectl 设置主机名为 $hostname"
        return 0
    fi

    # 非 systemd 系统：尝试写入 /etc/hostname 并使用 hostname 命令
    if [ -w /etc/hostname ] || [ -w /etc ]; then
        echo "$hostname" > /etc/hostname
        echo "已写入 /etc/hostname"
        if command -v hostname >/dev/null 2>&1; then
            hostname "$hostname"
            echo "已通过 hostname 命令设置当前主机名"
        fi
        return 0
    fi

    echo "错误：无法设置主机名（缺少权限或不受支持）" >&2
    return 1
}

# 设置主机名（可能需要 root 权限，若当前非 root 则通过 sudo 执行）
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        # 需要在 sudo 环境中重新调度函数，简单处理：整个脚本用 sudo 重跑或干脆用 sudo 执行命令
        # 这里采用直接调用 sudo 运行各命令的方式
        SUDO="sudo"
    else
        echo "错误：需要 root 权限，但未找到 sudo 命令" >&2
        exit 1
    fi
else
    SUDO=""
fi

# 执行主机名设置（若需要 sudo，则用 sudo 运行 hostnamectl 或写入文件）
if [ -n "$SUDO" ]; then
    $SUDO bash -c "$(declare -f set_hostname); set_hostname"
else
    set_hostname
fi

# 升级系统函数
upgrade_system() {
    # 检测包管理器并执行相应更新
    if command -v apt-get >/dev/null 2>&1; then
        # Debian/Ubuntu 系
        $SUDO apt-get update && \
        $SUDO apt-get upgrade -y && \
        $SUDO apt-get autoremove -y && \
        $SUDO apt-get clean
    elif command -v dnf >/dev/null 2>&1; then
        # Fedora/RHEL 8+ 系
        $SUDO dnf upgrade -y
    elif command -v yum >/dev/null 2>&1; then
        # RHEL/CentOS 7 系
        $SUDO yum update -y && \
        $SUDO yum clean all
    elif command -v pacman >/dev/null 2>&1; then
        # Arch/Manjaro 系
        $SUDO pacman -Syu --noconfirm
    elif command -v zypper >/dev/null 2>&1; then
        # openSUSE 系
        $SUDO zypper --non-interactive update
    elif command -v apk >/dev/null 2>&1; then
        # Alpine Linux
        $SUDO apk update && \
        $SUDO apk upgrade
    else
        echo "错误：未检测到支持的包管理器" >&2
        return 1
    fi
    return 0
}

# 执行系统升级
upgrade_system

echo "操作完成。"