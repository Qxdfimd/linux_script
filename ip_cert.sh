#!/usr/bin/env bash
# =============================================================================
# 通用公网IP证书自动签发脚本（支持 IPv4单栈 / IPv6单栈 / 双栈）
# 验证方式: HTTP-01（standalone / webroot）
# 证书颁发: Let's Encrypt（强制）
# 自动识别本机公网IP，无需手动输入
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[信息]${NC} $*"; }
warn()  { echo -e "${YELLOW}[警告]${NC} $*"; }
die()   { echo -e "${RED}[错误]${NC} $*"; exit 1; }

ACME_SH="$HOME/.acme.sh/acme.sh"

# =============================================================================
# 0. 依赖检查
# =============================================================================
check_deps() {
    for cmd in curl bash ip ss grep awk; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少必要命令: $cmd"
    done
}

# =============================================================================
# 1. 验证方式选择
# =============================================================================
select_validation() {
    echo "请选择 HTTP-01 验证方式："
    echo "  1) standalone（自动监听80端口，需要空闲80端口）"
    echo "  2) webroot   （将验证文件放到网站根目录，需Web服务器支持）"
    read -r -p "输入数字 [1/2] (默认1): " choice
    case "${choice:-1}" in
        1) VALIDATION="standalone" ;;
        2) VALIDATION="webroot" ;;
        *) VALIDATION="standalone" ;;
    esac

    if [[ "$VALIDATION" == "webroot" ]]; then
        echo -n "请输入网站根目录（例如 /var/www/html）: "
        read -r WEBROOT
        [[ -z "$WEBROOT" ]] && die "webroot目录不能为空"
        [[ -d "$WEBROOT" ]] || die "目录不存在: $WEBROOT"
        warn "请确认您的Web服务器已监听80端口，且能通过HTTP访问该目录下的 .well-known 路径"
        warn "若目标是纯IPv6，请确保Web服务器同时监听IPv6地址（[::]:80）"
    elif [[ "$VALIDATION" == "standalone" ]]; then
        # 检查80端口占用情况（仅IPv4，IPv6会单独检测）
        if ss -lnt | grep -q ':80 '; then
            die "IPv4的80端口已被占用，无法使用standalone模式。请改用webroot或释放端口。"
        fi
    fi
}

# =============================================================================
# 2. 自动检测本机公网IP（取第一个符合要求的）
# =============================================================================
get_public_ipv4() {
    local ip cidr
    while read -r cidr; do
        [[ -z "$cidr" ]] && continue
        ip="${cidr%%/*}"
        [[ "$ip" =~ ^10\.         ]] && continue
        [[ "$ip" =~ ^192\.168\.   ]] && continue
        [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && continue
        [[ "$ip" =~ ^127\.        ]] && continue
        [[ "$ip" =~ ^169\.254\.   ]] && continue
        echo "$ip"
        return 0
    done < <(ip -4 addr show scope global | awk '/inet /{print $2}')
    return 1
}

get_public_ipv6() {
    local ip cidr
    while read -r cidr; do
        [[ -z "$cidr" ]] && continue
        ip="${cidr%%/*}"
        [[ "$ip" == "::1"                ]] && continue
        [[ "$ip" =~ ^fe80::             ]] && continue
        [[ "$ip" =~ ^f[cd]00::          ]] && continue
        echo "$ip"
        return 0
    done < <(ip -6 addr show scope global | awk '/inet6 /{print $2}')
    return 1
}

detect_ips() {
    IP_LIST=()
    HAS_IPV4=0
    HAS_IPV6=0

    if PUBLIC_IPV4="$(get_public_ipv4)"; then
        HAS_IPV4=1
        IP_LIST+=("$PUBLIC_IPV4")
        info "检测到公网IPv4: $PUBLIC_IPV4"
    else
        warn "未检测到公网IPv4（可能处于NAT或未配置）"
    fi

    if PUBLIC_IPV6="$(get_public_ipv6)"; then
        HAS_IPV6=1
        IP_LIST+=("$PUBLIC_IPV6")
        info "检测到公网IPv6: $PUBLIC_IPV6"
    else
        warn "未检测到公网IPv6（可能未配置或仅内网）"
    fi

    [[ ${#IP_LIST[@]} -eq 0 ]] && die "本机没有可用公网IP，无法签发IP证书"
}

# =============================================================================
# 3. 安装/更新 acme.sh
# =============================================================================
setup_acme() {
    local email="$1"
    if [[ ! -f "$ACME_SH" ]]; then
        info "正在安装 acme.sh ..."
        curl -fsSL https://get.acme.sh | bash -s -- \
            ${email:+--email "$email"}
    else
        "$ACME_SH" --upgrade --force 2>/dev/null || warn "acme.sh 更新失败，将继续执行"
    fi
}

# =============================================================================
# 4. 签发证书
# =============================================================================
issue_cert() {
    local acme_args=()

    # 构建IP参数
    local ip_args=()
    for ip in "${IP_LIST[@]}"; do
        ip_args+=(-d "$ip")
    done

    if [[ "$VALIDATION" == "standalone" ]]; then
        # 自动检测IPv6，若存在公网IPv6则启用--listen-v6
        if [[ $HAS_IPV6 -eq 1 ]]; then
            acme_args+=(--standalone --listen-v6)
        else
            acme_args+=(--standalone)
        fi
    else
        acme_args+=(--webroot "$WEBROOT")
    fi

    info "开始签发IP证书，包含IP: ${IP_LIST[*]}"
    info "验证方式: $VALIDATION"
    if ! "$ACME_SH" --issue \
        "${acme_args[@]}" \
        --force \
        "${ip_args[@]}" \
        -k ec-256 \
        --server letsencrypt; then
        die "证书签发失败"
    fi
    info "证书签发成功 ✓"
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    check_deps
    select_validation
    detect_ips

    echo -n "请输入邮箱（用于续期通知，回车跳过）: "
    read -r acmesh_email

    setup_acme "$acmesh_email"
    issue_cert

    info "全部完成！"
    info "证书保存在: ~/.acme.sh/${IP_LIST[0]}_ecc/"
    info "请自行配置到Web服务器（例如Nginx/Apache）并设置续期后重载服务。"
}

main "$@"