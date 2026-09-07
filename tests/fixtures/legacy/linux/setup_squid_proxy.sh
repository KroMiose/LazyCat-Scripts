#!/bin/bash

# ==============================================================================
# 脚本名称: setup_squid_proxy.sh
# 功    能: 在 Linux 服务器上一键部署带 Basic Auth 认证的 Squid HTTP/HTTPS 代理。
#           自动生成随机账号密码、写入匿名化配置，并输出可直接使用的代理 URL。
# 适用系统: 基于 Debian/Ubuntu 的 Linux 系统（使用 systemd）
# 使用方法: sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/linux/setup_squid_proxy.sh)"
# ==============================================================================

# --- 颜色定义 ---
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_RED="\033[31m"
COLOR_CYAN="\033[36m"
COLOR_BOLD="\033[1m"
COLOR_RESET="\033[0m"

log_info()    { echo -e "${COLOR_BLUE}INFO: $1${COLOR_RESET}"; }
log_success() { echo -e "${COLOR_GREEN}SUCCESS: $1${COLOR_RESET}"; }
log_warn()    { echo -e "${COLOR_YELLOW}WARN: $1${COLOR_RESET}"; }
log_error()   { echo -e "${COLOR_RED}ERROR: $1${COLOR_RESET}" >&2; }
log_step()    { echo -e "\n${COLOR_BOLD}${COLOR_CYAN}>>> $1${COLOR_RESET}"; }

# --- 权限检查 ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本必须以 root 或 sudo 身份运行！"
        exit 1
    fi
}

# --- 检查 systemd ---
check_systemd() {
    if ! [ -d /run/systemd/system ]; then
        log_error "此脚本仅支持使用 systemd 的 Linux 系统。"
        exit 1
    fi
}

# --- 检查并安装依赖 ---
install_dependencies() {
    log_step "检查并安装依赖"

    if ! command -v apt-get &>/dev/null; then
        log_error "未找到 apt-get，此脚本仅支持 Debian/Ubuntu 系统。"
        exit 1
    fi

    local need_install=()
    command -v squid &>/dev/null    || need_install+=("squid")
    command -v htpasswd &>/dev/null || need_install+=("apache2-utils")

    if [ ${#need_install[@]} -eq 0 ]; then
        log_success "所有依赖已就绪（squid, apache2-utils）。"
        return
    fi

    log_info "正在安装缺失的依赖: ${need_install[*]}"
    apt-get update -qq
    apt-get install -y "${need_install[@]}"
    log_success "依赖安装完成。"
}

# --- 生成随机账号密码 ---
generate_credentials() {
    PROXY_USER="proxyuser$(openssl rand -hex 3)"
    PROXY_PASS="$(openssl rand -base64 12 | tr -d '/+=' | head -c 11)Aa1"
}

# --- 交互式配置 ---
interactive_config() {
    log_step "配置代理参数"

    # 代理端口
    read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 请输入代理监听端口 (默认: 51938): ${COLOR_RESET}")" input_port
    PROXY_PORT="${input_port:-51938}"

    # 账号密码
    echo ""
    log_info "将自动生成随机账号密码（推荐），也可手动指定。"
    read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 是否使用自动生成的随机账号密码？(Y/n): ${COLOR_RESET}")" use_random_creds
    if [[ "$use_random_creds" =~ ^[Nn]$ ]]; then
        read -p "  -> 请输入用户名: " PROXY_USER
        read -s -p "  -> 请输入密码: " PROXY_PASS
        echo ""
        if [ -z "$PROXY_USER" ] || [ -z "$PROXY_PASS" ]; then
            log_error "用户名和密码不能为空！"
            exit 1
        fi
    else
        generate_credentials
        log_info "已生成随机凭据：用户名=${PROXY_USER}"
    fi
}

# --- 写入 Squid 配置 ---
write_squid_config() {
    log_step "写入 Squid 配置文件"

    local SQUID_CONF="/etc/squid/squid.conf"
    local PASSWD_FILE="/etc/squid/passwd"

    # 备份原配置
    if [ -f "$SQUID_CONF" ]; then
        local backup_file="${SQUID_CONF}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$SQUID_CONF" "$backup_file"
        log_info "已备份原配置到: $backup_file"
    fi

    # 创建认证密码文件
    mkdir -p /etc/squid
    htpasswd -bc "$PASSWD_FILE" "$PROXY_USER" "$PROXY_PASS"
    # Squid 以 proxy 用户运行，需要确保其可读取密码文件
    chown root:proxy "$PASSWD_FILE"
    chmod 640 "$PASSWD_FILE"
    log_success "认证密码文件已创建: $PASSWD_FILE"

    # 写入新配置
    cat >"$SQUID_CONF" <<EOF
# ========== 基础设置 ==========
http_port ${PROXY_PORT}

# ========== 认证配置 ==========
auth_param basic program /usr/lib/squid/basic_ncsa_auth ${PASSWD_FILE}
auth_param basic realm Proxy Authentication Required
auth_param basic credentialsttl 2 hours
auth_param basic casesensitive on

acl authenticated proxy_auth REQUIRED

# ========== 访问控制 ==========
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl Safe_ports port 1025-65535
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access deny !authenticated
http_access allow authenticated
http_access deny all

# ========== 源IP隐藏（匿名化）==========
forwarded_for delete
via off
request_header_access X-Forwarded-For deny all
request_header_access Via deny all
request_header_access Cache-Control deny all
request_header_access Pragma deny all
reply_header_access X-Cache deny all
reply_header_access X-Cache-Lookup deny all
reply_header_access Via deny all
reply_header_access X-Squid-Error deny all

# ========== 性能和缓存 ==========
cache deny all
cache_mem 64 MB
maximum_object_size 10 MB

# ========== 日志 ==========
access_log /var/log/squid/access.log squid
cache_log /var/log/squid/cache.log

# ========== DNS ==========
dns_nameservers 8.8.8.8 1.1.1.1

# ========== 超时设置 ==========
connect_timeout 30 seconds
read_timeout 60 seconds
request_timeout 30 seconds

pid_filename /var/run/squid.pid
EOF

    log_success "Squid 配置文件已写入: $SQUID_CONF"
}

# --- 验证配置语法 ---
validate_config() {
    log_step "验证 Squid 配置语法"
    if squid -k parse 2>&1 | grep -q "ERROR"; then
        log_error "Squid 配置语法存在错误，请检查配置文件！"
        squid -k parse
        exit 1
    fi
    log_success "配置语法验证通过。"
}

# --- 启动服务 ---
start_service() {
    log_step "启动并设置 Squid 服务开机自启"
    systemctl restart squid
    systemctl enable squid
    log_success "Squid 服务已启动并设置为开机自启。"
}

# --- 验证部署结果 ---
verify_deployment() {
    log_step "验证部署结果"

    sleep 2

    local service_status
    service_status=$(systemctl is-active squid)
    if [ "$service_status" != "active" ]; then
        log_error "Squid 服务未能正常启动！请运行 'journalctl -u squid -n 50' 查看日志。"
        exit 1
    fi
    log_success "服务状态: active"

    if ss -tlnp | grep -q ":${PROXY_PORT}"; then
        log_success "端口监听正常: *:${PROXY_PORT}"
    else
        log_warn "未检测到端口 ${PROXY_PORT} 的监听，请稍后手动验证: ss -tlnp | grep ${PROXY_PORT}"
    fi
}

# --- 获取服务器公网 IP ---
get_public_ip() {
    local public_ip
    public_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || curl -s --max-time 5 https://icanhazip.com 2>/dev/null \
        || echo "")
    echo "$public_ip"
}

# --- 输出部署结果 ---
print_result() {
    local public_ip
    public_ip=$(get_public_ip)
    local display_ip="${public_ip:-<服务器公网IP>}"

    echo ""
    echo -e "${COLOR_BOLD}${COLOR_GREEN}============================================================${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_GREEN}  ✅ Squid 代理部署成功！${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_GREEN}============================================================${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_BOLD}代理地址:${COLOR_RESET}    ${display_ip}:${PROXY_PORT}"
    echo -e "  ${COLOR_BOLD}用户名:${COLOR_RESET}      ${PROXY_USER}"
    echo -e "  ${COLOR_BOLD}密码:${COLOR_RESET}        ${PROXY_PASS}"
    echo -e "  ${COLOR_BOLD}完整代理URL:${COLOR_RESET} http://${PROXY_USER}:${PROXY_PASS}@${display_ip}:${PROXY_PORT}"
    echo ""
    echo -e "${COLOR_CYAN}--- 验证命令 ---${COLOR_RESET}"
    echo -e "  # 测试代理连通性（应返回服务器公网IP）:"
    echo -e "  curl -x http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PROXY_PORT} http://httpbin.org/ip"
    echo ""
    echo -e "  # 验证请求头无代理特征（不应含 X-Forwarded-For、Via）:"
    echo -e "  curl -x http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PROXY_PORT} http://httpbin.org/headers"
    echo ""
    echo -e "  # 验证无认证时被拒绝（应返回 407）:"
    echo -e "  curl -x http://127.0.0.1:${PROXY_PORT} http://httpbin.org/ip"
    echo ""
    echo -e "${COLOR_CYAN}--- 常用管理命令 ---${COLOR_RESET}"
    echo -e "  tail -f /var/log/squid/access.log    # 实时查看访问日志"
    echo -e "  squid -k reconfigure                 # 重载配置（不重启服务）"
    echo -e "  htpasswd /etc/squid/passwd <用户名>  # 添加新用户"
    echo -e "  htpasswd -D /etc/squid/passwd <用户名> # 删除用户"
    echo -e "  ss -tnp | grep ${PROXY_PORT} | wc -l  # 查看当前连接数"
    echo ""
    echo -e "${COLOR_BOLD}${COLOR_GREEN}============================================================${COLOR_RESET}"
}

# --- 主逻辑 ---
main() {
    check_root
    check_systemd
    install_dependencies
    interactive_config
    write_squid_config
    validate_config
    start_service
    verify_deployment
    print_result
}

main "$@"
