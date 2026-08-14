#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# run.sh — Qxdfimd 快速维护脚本主菜单（自动安装依赖，显示系统信息）
# 用法: bash <(curl -Ls .../run.sh)
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

# 颜色与日志函数
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${GREEN}[信息]${NC} $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
err()  { echo -e "${RED}[错误]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }
step() { echo -e "${BLUE}── $* ──${NC}"; }

# 权限处理：非 root 时自动 sudo
if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        die "需要 root 权限，但未找到 sudo 命令"
    fi
else
    SUDO=""
fi

# =============================================================================
# 1. 依赖检测与安装
# =============================================================================
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
                *) echo "iproute2" ;;
            esac ;;
        grep) echo "grep" ;;
        awk) echo "gawk" ;;
        *) echo "" ;;
    esac
}

install_dependencies() {
    detect_pkg_manager
    local needed=() pkg cmd item

    # 检查缺失命令，收集对应包
    for cmd in curl bash ip ss grep awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            pkg=$(get_package_for_command "$cmd")
            [[ -n "$pkg" ]] && needed+=("$pkg")
        fi
    done

    # 系统工具包
    needed+=(util-linux coreutils)
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        needed+=(procps)
    else
        needed+=(procps-ng)
    fi

    # 去重
    local unique_needed=()
    for item in "${needed[@]}"; do
        if ! [[ " ${unique_needed[*]} " == *" $item "* ]]; then
            unique_needed+=("$item")
        fi
    done

    if [[ ${#unique_needed[@]} -gt 0 ]]; then
        warn "检测到系统缺少以下依赖：${unique_needed[*]}"
        read -r -p "是否立即安装？[Y/n] " confirm
        if [[ "$confirm" =~ ^[Yy]?$ ]]; then
            info "开始安装依赖..."
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
                    err "不支持的包管理器，请手动安装：${unique_needed[*]}"
                    return 1 ;;
            esac
            info "依赖安装完成"
        else
            warn "跳过安装，继续运行，但某些功能可能受限"
        fi
    fi
}

# =============================================================================
# 2. 下载并安全执行远程脚本
# =============================================================================
download() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$out"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$out" "$url"
    else
        return 1
    fi
}

run_remote() {
    local url="$1"
    warn "即将以 root 权限执行远程脚本：$url"
    warn "请确保来源可信，按回车继续，或 Ctrl+C 取消..."
    read -r -p ""
    local tmpfile
    tmpfile=$(mktemp)
    if ! download "$url" "$tmpfile"; then
        err "下载失败，请检查网络或 URL"
        rm -f "$tmpfile"
        return 1
    fi
    $SUDO bash "$tmpfile"
    rm -f "$tmpfile"
}

# =============================================================================
# 3. 系统信息展示
# =============================================================================
show_sysinfo() {
    if command -v fastfetch >/dev/null 2>&1; then
        fastfetch
    else
        warn "未检测到 fastfetch，尝试安装..."
        case "$PKG_MANAGER" in
            apt)
                $SUDO apt-get update && $SUDO apt-get install -y fastfetch && fastfetch || true ;;
            dnf)
                $SUDO dnf install -y fastfetch && fastfetch || true ;;
            yum)
                $SUDO yum install -y epel-release && $SUDO yum install -y fastfetch && fastfetch || true ;;
            pacman)
                $SUDO pacman -S --noconfirm fastfetch && fastfetch || true ;;
            zypper)
                $SUDO zypper --non-interactive install fastfetch && fastfetch || true ;;
            apk)
                $SUDO apk add fastfetch && fastfetch || true ;;
            *)
                warn "未找到合适的包管理器安装 fastfetch，使用 uname -a"
                uname -a ;;
        esac
    fi
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    install_dependencies || true
    show_sysinfo

    echo ""
    echo -e "${GREEN}══════════ Qxdfimd 快速维护脚本 ══════════${NC}"
    echo "----------------------------------------"

    while true; do
        echo ""
        echo "输入编号以运行："
        echo "01. 初始化（设置hostname，更新系统），只需运行一次"
        echo "02. 设置ZRAM & SWAP为RAM:ZRAM:SWAP = 1:1:1"
        echo "03. 申请IP证书（HTTP-01）"
        echo "04. 申请域名证书（HTTP-01，DNS-01）"
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
                run_remote "https://raw.githubusercontent.com/Qxdfimd/linux_script/refs/heads/main/init.sh" || true
                ;;
            02)
                run_remote "https://raw.githubusercontent.com/Qxdfimd/linux_script/refs/heads/main/zram_swap.sh" || true
                ;;
            03)
                run_remote "https://raw.githubusercontent.com/Qxdfimd/linux_script/refs/heads/main/ip_cert.sh" || true
                ;;
            04)
                run_remote "https://raw.githubusercontent.com/Qxdfimd/linux_script/refs/heads/main/domain_cert.sh" || true
                ;;
            05)
                run_remote "https://cdn.jsdelivr.net/gh/midoks/mdserver-web@latest/scripts/install.sh" || true
                ;;
            06)
                run_remote "https://raw.githubusercontent.com/nezhahq/scripts/refs/heads/main/install.sh" || true
                ;;
            07)
                run_remote "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh" || true
                ;;
            08)
                run_remote "https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh" || true
                ;;
            09)
                run_remote "https://alistgo.com/v3.sh" || true
                ;;
            00)
                info "退出脚本"
                break
                ;;
            *)
                warn "无效选项，请重新输入"
                ;;
        esac
    done
}

main "$@"
