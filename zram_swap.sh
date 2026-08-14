#!/bin/sh
# ═══════════════════════════════════════════════════════════════
#  跨发行版 ZRAM + swapfile 自动配置脚本 (POSIX sh)
#  自动识别包管理器并安装依赖
#  流程: 显示当前配置 → 清理旧配置 → 全新设置 → 展示结果
# ═══════════════════════════════════════════════════════════════
set -eu

# ── 颜色 ──
if command -v tput >/dev/null 2>&1 && tput setaf 1 >/dev/null 2>&1; then
    RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4); NC=$(tput sgr0)
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BLUE='\033[0;34m'; NC='\033[0m'
fi
info() { printf '%b%s%b\n' "$GREEN" "$*" "$NC"; }
warn() { printf '%b%s%b\n' "$YELLOW" "$*" "$NC"; }
err()  { printf '%b%s%b\n' "$RED" "$*" "$NC" >&2; }
step() { printf '%b%s%b\n' "$BLUE" "$*" "$NC"; }

# ──────────────────────────────────────────────
# 0. 权限检查
# ──────────────────────────────────────────────
[ "$(id -u)" -ne 0 ] && { err "请以 root 执行（sudo -i）"; exit 1; }

# ──────────────────────────────────────────────
# 1. 自动检测包管理器并安装缺失依赖
# ──────────────────────────────────────────────
install_deps() {
    missing=""
    for c in modprobe free df mkswap swapon swapoff sysctl dd fallocate; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    [ -z "$missing" ] && return 0  # 所有依赖已存在

    warn "缺少命令:$missing，将自动安装依赖..."
    # 通过包管理器安装 (util-linux 提供 mkswap/swapon/swapoff/sysctl/fallocate, coreutils 提供 dd/free/df)
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y util-linux coreutils procps
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y util-linux coreutils procps-ng
    elif command -v yum >/dev/null 2>&1; then
        yum install -y util-linux coreutils procps-ng
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm util-linux coreutils procps-ng
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install util-linux coreutils procps
    elif command -v apk >/dev/null 2>&1; then
        apk add util-linux coreutils procps
    elif command -v xbps-install >/dev/null 2>&1; then
        xbps-install -y util-linux coreutils procps-ng
    elif command -v emerge >/dev/null 2>&1; then
        emerge util-linux coreutils procps
    else
        err "无法识别包管理器，请手动安装缺失的命令: $missing"
        exit 1
    fi
    info "依赖安装完成"
}
install_deps

# ──────────────────────────────────────────────
# 2. 显示当前配置
# ──────────────────────────────────────────────
step "══════════ 当前系统状态 ══════════"
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

# ──────────────────────────────────────────────
# 3. 清除旧配置
# ──────────────────────────────────────────────
step "══════════ 清理旧配置 ══════════"

# 3.1 关闭所有 swap
swapoff -a 2>/dev/null || true

# 3.2 移除所有 zram 设备
remove_all_zram() {
    for z in /sys/block/zram*; do
        [ -e "$z" ] || continue
        dev="/dev/${z##*/}"
        swapoff "$dev" 2>/dev/null || true
        if command -v zramctl >/dev/null 2>&1; then
            zramctl -r "$dev" 2>/dev/null || true
        fi
        echo 1 > "$z/reset" 2>/dev/null || true
    done
}
remove_all_zram

# 3.3 删除脚本创建的 swapfile
swapfile="/swapfile"
[ -e "$swapfile" ] && { warn "删除旧 swapfile: $swapfile"; rm -f "$swapfile"; }

# 3.4 清理 fstab 中的 swapfile 条目
if grep -q "^$swapfile " /etc/fstab 2>/dev/null; then
    sed -i "\#^$swapfile #d" /etc/fstab
fi

# 3.5 清理 sysctl 配置（两种可能位置）
rm -f /etc/sysctl.d/99-zram.conf 2>/dev/null || true
if [ -f /etc/sysctl.conf ]; then
    sed -i '/^vm\.swappiness[[:space:]]*=/d;/^vm\.vfs_cache_pressure[[:space:]]*=/d;/^vm\.dirty_background_ratio[[:space:]]*=/d;/^vm\.dirty_ratio[[:space:]]*=/d;/^vm\.overcommit_memory[[:space:]]*=/d' /etc/sysctl.conf
fi

# 3.6 清理旧持久化文件（systemd / OpenRC local.d / rc.local 中的旧片段）
rm -f /etc/systemd/system/zram-swap.service /usr/local/bin/zram-swap-setup.sh 2>/dev/null || true
rm -f /etc/local.d/zram-swap.start /etc/local.d/zram-swap.stop 2>/dev/null || true
systemctl disable zram-swap.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
if [ -f /etc/rc.local ]; then
    sed -i '/zram-swap/d' /etc/rc.local 2>/dev/null || true
fi

# ──────────────────────────────────────────────
# 4. 内存与磁盘检查
# ──────────────────────────────────────────────
mem_mb=$(free -m | awk '/Mem:/ {print $2}')
[ -z "$mem_mb" ] && mem_mb=1024
info "物理内存: ${mem_mb} MB"

required_mb=$((mem_mb * 2))
available_mb=$(df -m / | awk 'NR==2 {print $4}')
info "根目录可用: $((available_mb/1024)) GB，需要: $((required_mb/1024)) GB"
if [ "$available_mb" -lt "$required_mb" ]; then
    err "磁盘空间不足！至少需要 $((required_mb/1024)) GB"
    exit 1
fi

# ──────────────────────────────────────────────
# 5. 检测压缩算法
# ──────────────────────────────────────────────
info ">>> 检测 ZRAM 压缩算法..."
modprobe zram 2>/dev/null || true
if [ ! -e /sys/block/zram0 ]; then
    err "无法加载 zram 模块，请确认内核支持（可尝试 modprobe zram）"
    exit 1
fi
algos=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "")
algo=""
for a in zstd lz4hc lzo-rle lz4 lzo; do
    if echo "$algos" | grep -qw "$a"; then algo="$a"; break; fi
done
[ -z "$algo" ] && { warn "未找到常用算法，使用 lzo"; algo="lzo"; }
info "选用的压缩算法: $algo"

# ──────────────────────────────────────────────
# 6. 写入 sysctl（自动选择位置并去重）
# ──────────────────────────────────────────────
write_sysctl() {
    if [ -d /etc/sysctl.d ]; then
        target="/etc/sysctl.d/99-zram.conf"
        cat > "$target" <<EOF
vm.swappiness = 100
vm.vfs_cache_pressure = 100
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20
vm.overcommit_memory = 0
EOF
    else
        target="/etc/sysctl.conf"
        sed -i '/^vm\.swappiness[[:space:]]*=/d;/^vm\.vfs_cache_pressure[[:space:]]*=/d;/^vm\.dirty_background_ratio[[:space:]]*=/d;/^vm\.dirty_ratio[[:space:]]*=/d;/^vm\.overcommit_memory[[:space:]]*=/d' "$target" 2>/dev/null || true
        cat >> "$target" <<EOF
vm.swappiness = 100
vm.vfs_cache_pressure = 100
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20
vm.overcommit_memory = 0
EOF
    fi
    info "内核参数已写入: $target"
    sysctl -p "$target" >/dev/null 2>&1 || sysctl -w vm.swappiness=100 vm.vfs_cache_pressure=100 vm.dirty_background_ratio=5 vm.dirty_ratio=20 vm.overcommit_memory=0 >/dev/null 2>&1 || true
}
write_sysctl

# ──────────────────────────────────────────────
# 7. 创建 ZRAM（直接操作 /sys，不依赖 zramctl）
# ──────────────────────────────────────────────
info ">>> 创建 ZRAM（${mem_mb} MB）"
modprobe -r zram 2>/dev/null || true
modprobe zram 2>/dev/null || true
zdev="/sys/block/zram0"
[ -e "$zdev" ] || { err "zram0 不存在"; exit 1; }
echo 1 > "$zdev/reset" 2>/dev/null || true
echo $((mem_mb * 1024 * 1024)) > "$zdev/disksize"
if [ -w "$zdev/comp_algorithm" ]; then
    echo "$algo" > "$zdev/comp_algorithm" 2>/dev/null || true
fi
mkswap /dev/zram0 >/dev/null 2>&1
swapon /dev/zram0 -p 100 2>/dev/null || swapon /dev/zram0
info "ZRAM 已启用（${mem_mb} MB，优先级 100）"

# ──────────────────────────────────────────────
# 8. 创建 swapfile（兼容 btrfs / fallocate 不可用）
# ──────────────────────────────────────────────
info ">>> 创建 swapfile（${mem_mb} MB）"
fs_type=$(df -T / | awk 'NR==2 {print $2}')
if [ "$fs_type" = "btrfs" ]; then
    warn "btrfs 文件系统：使用 dd 创建并设置 no CoW"
    chattr +C "$swapfile" 2>/dev/null || true
    dd if=/dev/zero of="$swapfile" bs=1M count="$mem_mb"
else
    fallocate -l "${mem_mb}M" "$swapfile" 2>/dev/null || dd if=/dev/zero of="$swapfile" bs=1M count="$mem_mb"
fi
chmod 600 "$swapfile"
mkswap "$swapfile" >/dev/null 2>&1
swapon "$swapfile" -p -2 2>/dev/null || swapon "$swapfile"

# fstab 持久化
if ! grep -q "^$swapfile " /etc/fstab 2>/dev/null; then
    echo "$swapfile none swap sw,pri=-2 0 0" >> /etc/fstab
fi

# ──────────────────────────────────────────────
# 9. ZRAM 持久化（自动适配 init 系统）
# ──────────────────────────────────────────────
persist_zram() {
    # 9.1 systemd
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        cat > /usr/local/bin/zram-swap-setup.sh <<EOF
#!/bin/sh
case "\$1" in
    start)
        modprobe zram 2>/dev/null || true
        echo $((mem_mb * 1024 * 1024)) > /sys/block/zram0/disksize
        echo "$algo" > /sys/block/zram0/comp_algorithm 2>/dev/null || true
        mkswap /dev/zram0 >/dev/null 2>&1
        swapon /dev/zram0 -p 100 2>/dev/null || swapon /dev/zram0
        ;;
    stop)
        swapoff /dev/zram0 2>/dev/null || true
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
        ;;
esac
EOF
        chmod +x /usr/local/bin/zram-swap-setup.sh
        cat > /etc/systemd/system/zram-swap.service <<EOF
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
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable zram-swap.service >/dev/null 2>&1 || true
        info "已创建 systemd 服务 zram-swap.service"
        return 0
    fi

    # 9.2 OpenRC local.d（Alpine 等）
    if [ -d /etc/local.d ]; then
        cat > /etc/local.d/zram-swap.start <<EOF
#!/bin/sh
modprobe zram 2>/dev/null || true
echo $((mem_mb * 1024 * 1024)) > /sys/block/zram0/disksize
echo "$algo" > /sys/block/zram0/comp_algorithm 2>/dev/null || true
mkswap /dev/zram0 >/dev/null 2>&1
swapon /dev/zram0 -p 100 2>/dev/null || swapon /dev/zram0
EOF
        cat > /etc/local.d/zram-swap.stop <<EOF
#!/bin/sh
swapoff /dev/zram0 2>/dev/null || true
echo 1 > /sys/block/zram0/reset 2>/dev/null || true
EOF
        chmod +x /etc/local.d/zram-swap.start /etc/local.d/zram-swap.stop
        if command -v rc-update >/dev/null 2>&1; then
            rc-update add local default >/dev/null 2>&1 || true
        fi
        info "已创建 OpenRC local.d 启动脚本"
        return 0
    fi

    # 9.3 兜底：/etc/rc.local（SysVinit / runit / 其他）
    if [ -f /etc/rc.local ] || [ -d /etc ]; then
        cat >> /etc/rc.local <<EOF
# ZRAM swap 配置
modprobe zram 2>/dev/null || true
echo $((mem_mb * 1024 * 1024)) > /sys/block/zram0/disksize
echo "$algo" > /sys/block/zram0/comp_algorithm 2>/dev/null || true
mkswap /dev/zram0 >/dev/null 2>&1
swapon /dev/zram0 -p 100 2>/dev/null || swapon /dev/zram0
EOF
        chmod +x /etc/rc.local 2>/dev/null || true
        info "已写入 /etc/rc.local 持久化"
    fi
}
persist_zram

# ──────────────────────────────────────────────
# 10. 结果展示
# ──────────────────────────────────────────────
echo ""
info "════════════ 配置完成 ════════════"
info "--- ZRAM 设备 ---"
command -v zramctl >/dev/null 2>&1 && zramctl || cat /sys/block/zram0/comp_algorithm 2>/dev/null
info "--- Swap 设备 ---"
swapon --show 2>/dev/null || swapon -s
info "--- 内存使用 ---"
free -h 2>/dev/null || free -m
info "--- 关键内核参数 ---"
sysctl vm.swappiness vm.vfs_cache_pressure vm.dirty_background_ratio vm.dirty_ratio vm.overcommit_memory 2>/dev/null || true
echo ""

# 可选：尝试安装并运行 fastfetch 显示系统信息（失败不影响）
info "--- 系统信息（尝试 fastfetch） ---"
if command -v fastfetch >/dev/null 2>&1; then
    fastfetch
else
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y fastfetch >/dev/null 2>&1 && fastfetch || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y fastfetch >/dev/null 2>&1 && fastfetch || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release >/dev/null 2>&1 && yum install -y fastfetch >/dev/null 2>&1 && fastfetch || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm fastfetch >/dev/null 2>&1 && fastfetch || true
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install fastfetch >/dev/null 2>&1 && fastfetch || true
    elif command -v apk >/dev/null 2>&1; then
        apk add fastfetch >/dev/null 2>&1 && fastfetch || true
    else
        warn "未找到合适的包管理器安装 fastfetch，使用 uname -a"
        uname -a
    fi
fi

info "所有配置已永久生效（重启后自动加载）"