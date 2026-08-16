#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# zram_swap.sh — 跨发行版 ZRAM + swapfile 自动配置脚本
# 自动识别包管理器并安装依赖
# 流程: 显示当前配置 → 检测 ZRAM 支持 → 清理旧配置 → 全新设置 → 展示结果
# 容器/受限环境: modprobe 失败时自动降级（保留已有 zram 或用 hot_add 重建，实在不行改用 2×RAM swapfile）
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

SWAPFILE="/swapfile"
ZRAM_OK=0   # 1=可使用 zram；0=不可用（容器/内核不支持）

# =============================================================================
# 1. 自动检测包管理器并安装缺失依赖
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
    elif command -v xbps-install >/dev/null 2>&1; then
        PKG_MANAGER="xbps"
    elif command -v emerge >/dev/null 2>&1; then
        PKG_MANAGER="emerge"
    else
        PKG_MANAGER="unknown"
    fi
}

install_deps() {
    detect_pkg_manager
    local missing=() c
    for c in modprobe free df mkswap swapon swapoff sysctl dd fallocate; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    warn "缺少命令：${missing[*]}，将自动安装依赖..."
    case "$PKG_MANAGER" in
        apt)
            $SUDO apt-get update && $SUDO apt-get install -y util-linux coreutils procps ;;
        dnf)
            $SUDO dnf install -y util-linux coreutils procps-ng ;;
        yum)
            $SUDO yum install -y util-linux coreutils procps-ng ;;
        pacman)
            $SUDO pacman -S --noconfirm util-linux coreutils procps-ng ;;
        zypper)
            $SUDO zypper --non-interactive install util-linux coreutils procps ;;
        apk)
            $SUDO apk add util-linux coreutils procps ;;
        xbps)
            $SUDO xbps-install -y util-linux coreutils procps-ng ;;
        emerge)
            $SUDO emerge util-linux coreutils procps ;;
        *)
            die "无法识别包管理器，请手动安装缺失的命令: ${missing[*]}" ;;
    esac
    info "依赖安装完成"
}

# =============================================================================
# 2. 显示当前配置
# =============================================================================
show_current() {
    step "当前系统状态"
    info "--- 内存与交换 ---"
    free -h 2>/dev/null || free -m
    info "--- 当前 swap 设备 ---"
    if swapon --show 2>/dev/null | grep -q .; then
        swapon --show
    else
        echo "（无 swap 设备）"
    fi
    info "--- 当前 zram 设备 ---"
    if ls /dev/zram* >/dev/null 2>&1; then
        if command -v zramctl >/dev/null 2>&1; then
            zramctl
        else
            ls -l /dev/zram*
        fi
    else
        echo "（无 zram 设备）"
    fi
    info "--- 相关内核参数 ---"
    sysctl vm.swappiness vm.vfs_cache_pressure vm.dirty_background_ratio vm.dirty_ratio vm.overcommit_memory 2>/dev/null || true
}

# =============================================================================
# 3. 清理旧配置
# =============================================================================
cleanup_old() {
    step "清理旧配置"

    # 关闭所有 swap
    $SUDO swapoff -a 2>/dev/null || true

    # 移除所有 zram 设备（仅当之后能重建时才移除，避免容器里删了无法重建）
    if [[ "$ZRAM_OK" == 1 ]]; then
        local z dev
        for z in /sys/block/zram*; do
            [[ -e "$z" ]] || continue
            dev="/dev/${z##*/}"
            $SUDO swapoff "$dev" 2>/dev/null || true
            if command -v zramctl >/dev/null 2>&1; then
                $SUDO zramctl -r "$dev" 2>/dev/null || true
            fi
            echo 1 | $SUDO tee "$z/reset" >/dev/null 2>&1 || true
        done
    else
        warn "当前环境无法重建 zram，保留现有 zram 设备不删除"
    fi

    # 删除脚本创建的 swapfile
    if [[ -e "$SWAPFILE" ]]; then
        warn "删除旧 swapfile: $SWAPFILE"
        $SUDO rm -f "$SWAPFILE"
    fi

    # 清理 fstab 中的 swapfile 条目
    if grep -q "^$SWAPFILE " /etc/fstab 2>/dev/null; then
        $SUDO sed -i "\#^$SWAPFILE #d" /etc/fstab
    fi

    # 清理 sysctl 配置（两种可能位置）
    $SUDO rm -f /etc/sysctl.d/99-zram.conf 2>/dev/null || true
    if [[ -f /etc/sysctl.conf ]]; then
        $SUDO sed -i '/^vm\.swappiness[[:space:]]*=/d;/^vm\.vfs_cache_pressure[[:space:]]*=/d;/^vm\.dirty_background_ratio[[:space:]]*=/d;/^vm\.dirty_ratio[[:space:]]*=/d;/^vm\.overcommit_memory[[:space:]]*=/d' /etc/sysctl.conf
    fi

    # 清理旧持久化文件（systemd / OpenRC local.d / rc.local 中的旧片段）
    $SUDO rm -f /etc/systemd/system/zram-swap.service /usr/local/bin/zram-swap-setup.sh 2>/dev/null || true
    $SUDO rm -f /etc/local.d/zram-swap.start /etc/local.d/zram-swap.stop 2>/dev/null || true
    $SUDO systemctl disable zram-swap.service 2>/dev/null || true
    $SUDO systemctl daemon-reload 2>/dev/null || true
    if [[ -f /etc/rc.local ]]; then
        $SUDO sed -i '/zram-swap/d' /etc/rc.local 2>/dev/null || true
    fi
}

# =============================================================================
# 4. 内存与磁盘检查
# =============================================================================
check_disk() {
    mem_mb=$(free -m | awk '/Mem:/ {print $2}')
    [[ -z "$mem_mb" ]] && mem_mb=1024
    info "物理内存: ${mem_mb} MB"

    local required_mb=$((mem_mb * 2))
    local available_mb
    available_mb=$(df -m / | awk 'NR==2 {print $4}')
    info "根目录可用: ${available_mb} MB，需要: ${required_mb} MB"
    if [[ "$available_mb" -lt "$required_mb" ]]; then
        die "磁盘空间不足！至少需要 ${required_mb} MB"
    fi
}

# =============================================================================
# 5. 检测压缩算法
# =============================================================================
detect_zram() {
    info "检测 ZRAM 支持..."
    ZRAM_OK=0
    if $SUDO modprobe zram 2>/dev/null; then
        ZRAM_OK=1
    elif [[ -d /sys/module/zram || -e /sys/class/zram-control || -e /sys/block/zram0 ]]; then
        ZRAM_OK=1
        warn "modprobe 不可用（容器环境常见），但 zram 模块已就绪，直接使用"
    fi

    if [[ "$ZRAM_OK" == 1 ]]; then
        # 确保有设备可读取压缩算法（容器内 modprobe 失败时用 hot_add 创建设备）
        if [[ ! -e /sys/block/zram0 ]] && [[ -e /sys/class/zram-control ]]; then
            echo 1 | $SUDO tee /sys/class/zram-control/hot_add >/dev/null 2>&1 || true
        fi
        if [[ -e /sys/block/zram0 ]]; then
            local algos a
            algos=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "")
            algo=""
            for a in zstd lz4hc lzo-rle lz4 lzo; do
                if echo "$algos" | grep -qw "$a"; then
                    algo="$a"
                    break
                fi
            done
            [[ -z "$algo" ]] && { warn "未找到常用算法，使用 lzo"; algo="lzo"; }
            info "选用的压缩算法: $algo"
        else
            ZRAM_OK=0
            warn "zram 模块存在但无法创建设备，将仅使用 swapfile（2×RAM）"
        fi
    else
        warn "无法加载 zram 模块（容器或内核不支持），将仅使用 swapfile（2×RAM）"
    fi
}

# =============================================================================
# 6. 写入 sysctl（自动选择位置并去重）
# =============================================================================
write_sysctl() {
    local target
    if [[ -d /etc/sysctl.d ]]; then
        target="/etc/sysctl.d/99-zram.conf"
        $SUDO tee "$target" >/dev/null <<'EOF'
vm.swappiness = 100
vm.vfs_cache_pressure = 100
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20
vm.overcommit_memory = 0
EOF
    else
        target="/etc/sysctl.conf"
        $SUDO sed -i '/^vm\.swappiness[[:space:]]*=/d;/^vm\.vfs_cache_pressure[[:space:]]*=/d;/^vm\.dirty_background_ratio[[:space:]]*=/d;/^vm\.dirty_ratio[[:space:]]*=/d;/^vm\.overcommit_memory[[:space:]]*=/d' "$target" 2>/dev/null || true
        $SUDO tee -a "$target" >/dev/null <<'EOF'
vm.swappiness = 100
vm.vfs_cache_pressure = 100
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20
vm.overcommit_memory = 0
EOF
    fi
    info "内核参数已写入: $target"
    $SUDO sysctl -p "$target" >/dev/null 2>&1 \
        || $SUDO sysctl -w vm.swappiness=100 vm.vfs_cache_pressure=100 vm.dirty_background_ratio=5 vm.dirty_ratio=20 vm.overcommit_memory=0 >/dev/null 2>&1 \
        || true
}

# =============================================================================
# 7. 创建 ZRAM（直接操作 /sys，不依赖 zramctl）
# =============================================================================
setup_zram() {
    [[ "$ZRAM_OK" == 1 ]] || { warn "跳过 ZRAM（当前环境不支持）"; return 0; }
    info "创建 ZRAM（${mem_mb} MB）"
    $SUDO modprobe -r zram 2>/dev/null || true
    $SUDO modprobe zram 2>/dev/null || true

    # 确保 zram0 设备存在（容器内 modprobe 失败时用 hot_add 创建）
    if [[ ! -e /sys/block/zram0 ]] && [[ -e /sys/class/zram-control ]]; then
        echo 1 | $SUDO tee /sys/class/zram-control/hot_add >/dev/null 2>&1 || true
    fi

    local zdev="/sys/block/zram0"
    if [[ ! -e "$zdev" ]]; then
        warn "无法创建 zram0 设备，降级为仅使用 swapfile（2×RAM）"
        ZRAM_OK=0
        return 0
    fi
    echo 1 | $SUDO tee "$zdev/reset" >/dev/null 2>&1 || true
    echo $((mem_mb * 1024 * 1024)) | $SUDO tee "$zdev/disksize" >/dev/null 2>&1 || {
        warn "无法设置 zram 大小（sysfs 只读？），降级为仅使用 swapfile（2×RAM）"
        ZRAM_OK=0
        return 0
    }
    if [[ -w "$zdev/comp_algorithm" ]]; then
        echo "$algo" | $SUDO tee "$zdev/comp_algorithm" >/dev/null 2>&1 || true
    fi
    if ! $SUDO mkswap /dev/zram0 >/dev/null 2>&1; then
        warn "mkswap zram0 失败，降级为仅使用 swapfile（2×RAM）"
        ZRAM_OK=0
        return 0
    fi
    if ! $SUDO swapon /dev/zram0 -p 100 2>/dev/null && ! $SUDO swapon /dev/zram0 2>/dev/null; then
        warn "启用 ZRAM 失败，降级为仅使用 swapfile（2×RAM）"
        ZRAM_OK=0
        return 0
    fi
    info "ZRAM 已启用（${mem_mb} MB，优先级 100）"
}

# =============================================================================
# 8. 创建 swapfile（兼容 btrfs / fallocate 不可用）
# =============================================================================
setup_swapfile() {
    local swap_mb="$mem_mb"
    if [[ "$ZRAM_OK" != 1 ]]; then
        swap_mb=$((mem_mb * 2))
        warn "ZRAM 不可用，swapfile 自动扩容为 2×RAM（${swap_mb} MB）"
    fi
    info "创建 swapfile（${swap_mb} MB）"
    local fs_type
    fs_type=$(df -T / | awk 'NR==2 {print $2}')
    if [[ "$fs_type" == "btrfs" ]]; then
        warn "btrfs 文件系统：使用 dd 创建并设置 no CoW"
        $SUDO chattr +C "$SWAPFILE" 2>/dev/null || true
        $SUDO dd if=/dev/zero of="$SWAPFILE" bs=1M count="$swap_mb"
    else
        $SUDO fallocate -l "${swap_mb}M" "$SWAPFILE" 2>/dev/null \
            || $SUDO dd if=/dev/zero of="$SWAPFILE" bs=1M count="$swap_mb"
    fi
    $SUDO chmod 600 "$SWAPFILE"
    $SUDO mkswap "$SWAPFILE" >/dev/null 2>&1
    $SUDO swapon "$SWAPFILE" -p -2 2>/dev/null || $SUDO swapon "$SWAPFILE"

    # fstab 持久化
    if ! grep -q "^$SWAPFILE " /etc/fstab 2>/dev/null; then
        echo "$SWAPFILE none swap sw,pri=-2 0 0" | $SUDO tee -a /etc/fstab >/dev/null
    fi
}

# =============================================================================
# 9. ZRAM 持久化（自动适配 init 系统）
# =============================================================================
persist_zram() {
    [[ "$ZRAM_OK" == 1 ]] || { warn "ZRAM 不可用，跳过持久化"; return 0; }

    # systemd
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        $SUDO tee /usr/local/bin/zram-swap-setup.sh >/dev/null <<EOF
#!/bin/sh
case "\$1" in
    start)
        modprobe zram 2>/dev/null || true
        [ -e /sys/block/zram0 ] || echo 1 > /sys/class/zram-control/hot_add 2>/dev/null || true
        echo $((mem_mb * 1024 * 1024)) > /sys/block/zram0/disksize
        echo "$algo" > /sys/block/zram0/comp_algorithm 2>/dev/null || true
        mkswap /dev/zram0 >/dev/null 2>&1
        swapon /dev/zram0 -p 100 2>/dev/null || swapon /dev/zram0 2>/dev/null || true
        ;;
    stop)
        swapoff /dev/zram0 2>/dev/null || true
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
        ;;
esac
EOF
        $SUDO chmod +x /usr/local/bin/zram-swap-setup.sh
        $SUDO tee /etc/systemd/system/zram-swap.service >/dev/null <<'EOF'
[Unit]
Description=ZRAM Swap setup
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/zram-swap-setup.sh start
ExecStop=/usr/local/bin/zram-swap-setup.sh stop

[Install]
WantedBy=multi-user.target
EOF
        $SUDO systemctl daemon-reload 2>/dev/null || true
        $SUDO systemctl enable zram-swap.service >/dev/null 2>&1 || true
        info "已创建 systemd 服务 zram-swap.service"
        return 0
    fi

    # OpenRC local.d（Alpine 等）
    if [[ -d /etc/local.d ]]; then
        $SUDO tee /etc/local.d/zram-swap.start >/dev/null <<EOF
#!/bin/sh
modprobe zram 2>/dev/null || true
[ -e /sys/block/zram0 ] || echo 1 > /sys/class/zram-control/hot_add 2>/dev/null || true
echo $((mem_mb * 1024 * 1024)) > /sys/block/zram0/disksize
echo "$algo" > /sys/block/zram0/comp_algorithm 2>/dev/null || true
mkswap /dev/zram0 >/dev/null 2>&1
swapon /dev/zram0 -p 100 2>/dev/null || swapon /dev/zram0 2>/dev/null || true
EOF
        $SUDO tee /etc/local.d/zram-swap.stop >/dev/null <<'EOF'
#!/bin/sh
swapoff /dev/zram0 2>/dev/null || true
echo 1 > /sys/block/zram0/reset 2>/dev/null || true
EOF
        $SUDO chmod +x /etc/local.d/zram-swap.start /etc/local.d/zram-swap.stop
        if command -v rc-update >/dev/null 2>&1; then
            $SUDO rc-update add local default >/dev/null 2>&1 || true
        fi
        info "已创建 OpenRC local.d 启动脚本"
        return 0
    fi

    # 兜底：/etc/rc.local（SysVinit / runit / 其他）
    if [[ -f /etc/rc.local ]] || [[ -d /etc ]]; then
        $SUDO tee -a /etc/rc.local >/dev/null <<EOF
# ZRAM swap 配置
modprobe zram 2>/dev/null || true
[ -e /sys/block/zram0 ] || echo 1 > /sys/class/zram-control/hot_add 2>/dev/null || true
echo $((mem_mb * 1024 * 1024)) > /sys/block/zram0/disksize
echo "$algo" > /sys/block/zram0/comp_algorithm 2>/dev/null || true
mkswap /dev/zram0 >/dev/null 2>&1
swapon /dev/zram0 -p 100 2>/dev/null || swapon /dev/zram0 2>/dev/null || true
EOF
        $SUDO chmod +x /etc/rc.local 2>/dev/null || true
        info "已写入 /etc/rc.local 持久化"
    fi
}

# =============================================================================
# 10. 结果展示与系统信息
# =============================================================================
show_result() {
    echo ""
    step "配置完成"
    if [[ "$ZRAM_OK" == 1 ]]; then
        info "--- ZRAM 设备 ---"
        if command -v zramctl >/dev/null 2>&1; then
            zramctl
        else
            cat /sys/block/zram0/comp_algorithm 2>/dev/null || true
        fi
    fi
    info "--- Swap 设备 ---"
    swapon --show 2>/dev/null || swapon -s
    info "--- 内存使用 ---"
    free -h 2>/dev/null || free -m
    info "--- 关键内核参数 ---"
    sysctl vm.swappiness vm.vfs_cache_pressure vm.dirty_background_ratio vm.dirty_ratio vm.overcommit_memory 2>/dev/null || true
    echo ""
}

show_sysinfo() {
    info "--- 系统信息（尝试 fastfetch） ---"
    if command -v fastfetch >/dev/null 2>&1; then
        fastfetch
    else
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
            xbps)
                $SUDO xbps-install -y fastfetch && fastfetch || true ;;
            emerge)
                $SUDO emerge fastfetch && fastfetch || true ;;
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
    install_deps
    show_current
    detect_zram
    cleanup_old
    check_disk
    write_sysctl
    setup_zram
    setup_swapfile
    persist_zram
    show_result
    show_sysinfo

    info "所有配置已永久生效（重启后自动加载）"
}

main "$@"
