#!/usr/bin/env bash

# 防止使用未定义变量
set -u

# 定义颜色，提升可读性
RESET='\033[0m'
BOLD='\033[1m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'

# 根据权限设置 SUDO
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "错误：需要 root 权限，但未找到 sudo 命令" >&2
        exit 1
    fi
else
    SUDO=""
fi

# ========== 自动安装依赖 ==========
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
    else
        PKG_MANAGER="unknown"
    fi
}

get_package_for_command() {
    local cmd="$1"
    case "$cmd" in
        curl) echo "curl" ;;
        bash) echo "bash" ;;
        ip|ss)
            case "$PKG_MANAGER" in
                apt) echo "iproute2" ;;
                dnf|yum) echo "iproute" ;;
                pacman|zypper|apk) echo "iproute2" ;;
                *) echo "iproute2" ;;
            esac ;;
        grep) echo "grep" ;;
        awk) echo "gawk" ;;
        *) echo "" ;;
    esac
}

install_dependencies() {
    detect_pkg_manager
    local needed=()
    local pkg
    local cmd

    # 检查命令缺失，收集对应包
    for cmd in curl bash ip ss grep awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            pkg=$(get_package_for_command "$cmd")
            if [ -n "$pkg" ]; then
                needed+=("$pkg")
            fi
        fi
    done

    # 系统工具包
    needed+=(util-linux coreutils)

    # procps-ng 在不同发行版的名称差异
    case "$PKG_MANAGER" in
        apt) needed+=(procps) ;;
        *) needed+=(procps-ng) ;;
    esac

    # 去重
    local unique_needed=()
    for item in "${needed[@]}"; do
        if ! [[ " ${unique_needed[@]} " =~ " $item " ]]; then
            unique_needed+=("$item")
        fi
    done

    if [ ${#unique_needed[@]} -gt 0 ]; then
        echo -e "${YELLOW}检测到系统缺少以下依赖：${unique_needed[*]}${RESET}"
        read -r -p "是否立即安装？[Y/n] " confirm
        if [[ "$confirm" =~ ^[Yy]?$ ]]; then
            echo -e "${GREEN}开始安装依赖...${RESET}"
            case "$PKG_MANAGER" in
                apt)
                    $SUDO apt-get update && $SUDO apt-get install -y "${unique_needed[@]}" ;;
                dnf)
                    $SUDO dnf install -y "${unique_needed[@]}" ;;
                yum)
                    $SUDO yum install -y "${unique_needed[@]}" ;;
                pacman)
                    $SUDO pacman -S --noconfirm "${unique_needed[@]}" ;;
                zypper)
                    $SUDO zypper --non-interactive install "${unique_needed[@]}" ;;
                apk)
                    $SUDO apk add "${unique_needed[@]}" ;;
                *)
                    echo -e "${RED}不支持的包管理器，请手动安装：${unique_needed[*]}${RESET}"
                    return 1 ;;
            esac
            echo -e "${GREEN}依赖安装完成${RESET}"
        else
            echo -e "${YELLOW}跳过安装，继续运行，但某些功能可能受限。${RESET}"
        fi
    fi
}

install_dependencies   # 调用安装

# 显示系统信息
echo "----- 系统信息 -----"
if command -v fastfetch >/dev/null 2>&1; then
    fastfetch
else
    echo -e "${YELLOW}未检测到 fastfetch，尝试安装...${RESET}"
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update && $SUDO apt-get install -y fastfetch && fastfetch || true
    elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y fastfetch && fastfetch || true
    elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y epel-release && $SUDO yum install -y fastfetch && fastfetch || true
    elif command -v pacman >/dev/null 2>&1; then
        $SUDO pacman -S --noconfirm fastfetch && fastfetch || true
    elif command -v zypper >/dev/null 2>&1; then
        $SUDO zypper --non-interactive install fastfetch && fastfetch || true
    elif command -v apk >/dev/null 2>&1; then
        $SUDO apk add fastfetch && fastfetch || true
    else
        echo -e "${RED}未找到合适的包管理器，跳过 fastfetch 安装，回退至 uname 。${RESET}"
        uname -a
    fi
fi

# 显示横幅
echo -e "${BOLD}Qxdfimd的快速维护脚本${RESET}"
echo "----------------------------------------"

# 检查必要命令（只返回状态码）
check_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo -e "${RED}错误：未找到命令 '$1'，请先安装${RESET}" >&2
        return 1
    fi
}

# 设置下载命令
if command -v curl >/dev/null 2>&1; then
    DOWNLOAD_CMD="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOAD_CMD="wget -qO-"
else
    echo -e "${RED}错误：需要 curl 或 wget 来下载远程脚本${RESET}" >&2
    exit 1
fi

# 安全运行远程脚本的函数（下载到临时文件后执行）
run_remote() {
    local url="$1"
    echo -e "${YELLOW}即将从远程执行脚本：${RESET}$url"
    echo -e "${YELLOW}请确保来源可信，按回车继续，或 Ctrl+C 取消...${RESET}"
    read -r -p ""
    local tmpfile
    tmpfile=$(mktemp)
    if [ -z "$DOWNLOAD_CMD" ]; then
        echo -e "${RED}下载命令未设置${RESET}" >&2
        return 1
    fi
    if ! $DOWNLOAD_CMD "$url" -o "$tmpfile" 2>/dev/null; then
        echo -e "${RED}下载失败，请检查网络或 URL${RESET}" >&2
        rm -f "$tmpfile"
        return 1
    fi
    bash "$tmpfile"
    rm -f "$tmpfile"
}

# 主循环
while true; do
    echo ""
    echo "输入编号以运行："
    echo "01. 初始化，只需运行一次"
    echo "02. 设置ZRAM & SWAP"
    echo "03. 申请IP证书"
    echo "04. 申请域名证书"
    echo "05. 安装mdserver-web"
    echo "06. 安装nezha-dashboard"
    echo "07. 安装3X-UI"
    echo "08. 安装S-UI"
    echo "09. 安装AList"
    echo "00. 退出"
    echo ""
    printf "请输入选择："
    read -r choice

    case "$choice" in
        01)
            echo "执行初始化..."
            run_remote "https://raw.githubusercontent.com/qxdfimd/linux_script/main/init.sh"
            ;;
        02)
            echo "设置ZRAM & SWAP..."
            run_remote "https://raw.githubusercontent.com/qxdfimd/linux_script/main/zram_swap.sh"
            ;;
        03)
            echo "申请IP证书..."
            run_remote "https://raw.githubusercontent.com/qxdfimd/linux_script/main/ip_cert.sh"
            ;;
        04)
            echo "申请域名证书..."
            run_remote "https://raw.githubusercontent.com/qxdfimd/linux_script/main/domain_cert.sh"
            ;;
        05)
            echo "安装mdserver-web..."
            run_remote "https://cdn.jsdelivr.net/gh/midoks/mdserver-web@latest/scripts/install.sh"
            ;;
        06)
            echo "安装nezha-dashboard..."
            if ! curl -fsSL "https://raw.githubusercontent.com/nezhahq/scripts/refs/heads/main/install.sh" -o nezha.sh 2>/dev/null; then
                echo -e "${RED}下载失败，请检查网络${RESET}" >&2
                continue
            fi
            chmod +x nezha.sh
            $SUDO ./nezha.sh
            rm -f nezha.sh
            ;;
        07)
            echo "安装3X-UI..."
            run_remote "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
            ;;
        08)
            echo "安装S-UI..."
            run_remote "https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh"
            ;;
        09)
            echo "安装AList..."
            if ! curl -fsSL "https://alistgo.com/v3.sh" -o v3.sh 2>/dev/null; then
                echo -e "${RED}下载失败，请检查网络${RESET}" >&2
                continue
            fi
            bash v3.sh
            rm -f v3.sh
            ;;
        00)
            echo "退出脚本。"
            break
            ;;
        *)
            echo -e "${RED}无效选项，请重新输入。${RESET}"
            ;;
    esac
done