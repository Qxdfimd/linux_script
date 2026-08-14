#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# init.sh — 初始化（设置 hostname、更新系统）
# 用法: bash <(curl -Ls .../init.sh)
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
# 1. 设置主机名
# =============================================================================
set_hostname() {
    # 优先使用 hostnamectl（systemd）
    if command -v hostnamectl >/dev/null 2>&1; then
        $SUDO hostnamectl set-hostname "$hostname"
        info "已通过 hostnamectl 设置主机名为 $hostname"
        return 0
    fi

    # 非 systemd 系统：写入 /etc/hostname 并使用 hostname 命令
    echo "$hostname" | $SUDO tee /etc/hostname >/dev/null
    info "已写入 /etc/hostname"
    if command -v hostname >/dev/null 2>&1; then
        $SUDO hostname "$hostname"
        info "已通过 hostname 命令设置当前主机名"
    fi
}

# =============================================================================
# 2. 升级系统
# =============================================================================
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
        die "未检测到支持的包管理器"
    fi
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    # 提示输入主机名
    read -r -p "请输入hostname: " hostname
    [[ -n "$hostname" ]] || die "hostname 不能为空"

    step "设置主机名"
    set_hostname || warn "主机名设置失败，继续执行"

    step "更新系统"
    upgrade_system || warn "系统升级失败，请手动检查"

    info "操作完成"
}

main "$@"
