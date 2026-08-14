#!/usr/bin/env bash
# =============================================================================
# 通用域名证书自动签发脚本（支持 HTTP-01 / DNS-01，含 IPv6 单栈）
# 验证方式:
#   1) HTTP-01   - standalone   (自动监听80端口，支持IPv6单栈)
#                  - webroot     (使用网站根目录)
#   2) DNS-01    - Cloudflare   (自动添加TXT记录)
#                  - 手动模式     (手动添加TXT记录)
# 证书颁发: Let's Encrypt（强制）
# 自动识别 IPv6 环境，纯 IPv6 单栈时自动启用 --listen-v6
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
# 1. 检测本机 IPv4 / IPv6 环境（用于 HTTP-01 standalone）
# =============================================================================
detect_network() {
    HAS_IPV4=0
    HAS_IPV6=0
    IS_IPV6_ONLY=0

    if ip -4 addr show scope global >/dev/null 2>&1; then
        HAS_IPV4=1
        info "检测到本机存在公网IPv4地址"
    else
        warn "未检测到公网IPv4地址"
    fi

    if ip -6 addr show scope global >/dev/null 2>&1; then
        HAS_IPV6=1
        info "检测到本机存在公网IPv6地址"
    else
        warn "未检测到公网IPv6地址"
    fi

    if [[ $HAS_IPV4 -eq 0 && $HAS_IPV6 -eq 1 ]]; then
        IS_IPV6_ONLY=1
        info "当前为 IPv6 单栈环境（无公网IPv4）"
    fi
}

# =============================================================================
# 2. 验证方式选择
# =============================================================================
select_validation() {
    echo "请选择验证方式："
    echo "  1) HTTP-01   - 占用80端口或使用网站目录"
    echo "  2) DNS-01    - Cloudflare API 自动验证"
    echo "  3) DNS-01    - 手动添加TXT记录"
    read -r -p "输入数字 [1/2/3] (默认1): " choice
    case "${choice:-1}" in
        1) VALIDATION="http" ;;
        2) VALIDATION="dns_cf" ;;
        3) VALIDATION="dns_manual" ;;
        *) VALIDATION="http" ;;
    esac

    if [[ "$VALIDATION" == "http" ]]; then
        echo "  请选择 HTTP-01 方式："
        echo "    1) standalone  (自动监听80端口，需空闲)"
        echo "    2) webroot     (使用网站根目录)"
        read -r -p "    输入数字 [1/2] (默认1): " http_choice
        case "${http_choice:-1}" in
            1) HTTP_MODE="standalone" ;;
            2) HTTP_MODE="webroot" ;;
            *) HTTP_MODE="standalone" ;;
        esac

        detect_network

        if [[ "$HTTP_MODE" == "standalone" ]]; then
            # 检查IPv4 80端口（若存在IPv4）
            if [[ $HAS_IPV4 -eq 1 ]] && ss -lnt4 | grep -q ':80 '; then
                die "IPv4的80端口已被占用，无法使用standalone。请改用webroot或释放端口。"
            fi
            # 检查IPv6 80端口（若存在IPv6）
            if [[ $HAS_IPV6 -eq 1 ]] && ss -lnt6 | grep -q ':80 '; then
                die "IPv6的80端口已被占用，无法使用standalone。请改用webroot或释放端口。"
            fi
        else
            echo -n "    请输入网站根目录（例如 /var/www/html）: "
            read -r WEBROOT
            [[ -z "$WEBROOT" ]] && die "webroot目录不能为空"
            [[ -d "$WEBROOT" ]] || die "目录不存在: $WEBROOT"
            if [[ $IS_IPV6_ONLY -eq 1 ]]; then
                warn "当前为IPv6单栈环境，请确保Web服务器监听 [::]:80，且能通过IPv6访问 .well-known 路径"
            else
                warn "请确认您的Web服务器已监听80端口，且能通过HTTP访问该目录下的 .well-known 路径"
            fi
        fi
    elif [[ "$VALIDATION" == "dns_cf" ]]; then
        echo -n "请输入 Cloudflare API Token: "
        read -r cf_token
        [[ -z "$cf_token" ]] && die "Token不能为空"
        export CF_Token="$cf_token"
    else
        info "手动DNS模式：请提前准备好DNS服务商的TXT记录添加能力"
    fi
}

# =============================================================================
# 3. 输入域名列表（支持逗号分隔、通配符，自动去空格）
# =============================================================================
get_domains() {
    echo "请输入域名（多个用逗号分隔，支持 * 通配符）: "
    read -r input_domains
    [[ -z "$input_domains" ]] && die "未输入域名"
    IFS=',' read -ra DOMAIN_ARRAY <<< "$input_domains"
    DOMAIN_ARRAY=("${DOMAIN_ARRAY[@]// /}")
    DOMAIN_ARRAY=("${DOMAIN_ARRAY[@]//\t/}")
    [[ ${#DOMAIN_ARRAY[@]} -eq 0 ]] && die "域名列表为空"
    info "将签发域名: ${DOMAIN_ARRAY[*]}"
}

# =============================================================================
# 4. 安装/更新 acme.sh
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
# 5. 签发证书
# =============================================================================
issue_cert() {
    local acme_args=()

    # 构建域名参数
    local domain_args=()
    for domain in "${DOMAIN_ARRAY[@]}"; do
        domain_args+=(-d "$domain")
    done

    case "$VALIDATION" in
        http)
            if [[ "$HTTP_MODE" == "standalone" ]]; then
                # 存在IPv6（含纯IPv6单栈）时启用 --listen-v6
                if [[ $HAS_IPV6 -eq 1 ]]; then
                    acme_args+=(--standalone --listen-v6)
                else
                    acme_args+=(--standalone)
                fi
            else
                acme_args+=(--webroot "$WEBROOT")
            fi
            ;;
        dns_cf)
            acme_args+=(--dns dns_cf)
            ;;
        dns_manual)
            acme_args+=(--dns)
            ;;
    esac

    info "开始签发证书，域名: ${DOMAIN_ARRAY[*]}"
    info "验证方式: $VALIDATION ($([ "$VALIDATION" == "http" ] && echo "$HTTP_MODE" || echo "DNS"))"
    if [[ $IS_IPV6_ONLY -eq 1 && "$VALIDATION" == "http" ]]; then
        info "IPv6单栈HTTP-01模式：已自动启用 --listen-v6"
    fi

    if ! "$ACME_SH" --issue \
        "${acme_args[@]}" \
        --force \
        "${domain_args[@]}" \
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
    get_domains

    echo -n "请输入邮箱（用于续期通知，回车跳过）: "
    read -r acmesh_email

    setup_acme "$acmesh_email"
    issue_cert

    info "全部完成！"
    info "证书保存在: ~/.acme.sh/${DOMAIN_ARRAY[0]}_ecc/"
    info "请自行配置到Web服务器（例如Nginx/Apache）并设置续期后重载服务。"
}

main "$@"