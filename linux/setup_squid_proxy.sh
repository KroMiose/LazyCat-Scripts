#!/bin/bash

# ==============================================================================
# 脚本名称: setup_squid_proxy.sh
# 功    能: 在 Linux 服务器上一键部署带 Basic Auth 认证的 Squid HTTP/HTTPS 代理。
#           自动生成随机账号密码、写入匿名化配置，并输出可直接使用的代理 URL。
# 适用系统: 基于 Debian/Ubuntu 的 Linux 系统（使用 systemd）
# 使用方法: sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/linux/setup_squid_proxy.sh)"
# ==============================================================================

set -euo pipefail

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

# Linux flock releases with the last process descriptor, including after
# SIGKILL. Keep the inode in /run; unlinking a held lock creates two lock domains.
lock_operation() {
    local lock=/run/lazycat-squid.lock
    command -v flock >/dev/null || { log_error '缺少 flock，未安装依赖或修改配置。'; return 1; }
    [[ ! -L "$lock" && ( ! -e "$lock" || -f "$lock" ) ]] || { log_error 'Squid 操作锁路径异常，未修改系统。'; return 3; }
    (umask 077; : >> "$lock") || return 1
    exec 9>>"$lock"
    flock -n 9 || { log_error '另一项 Squid 安装或更新正在进行，未修改系统。'; return 3; }
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
    command -v ss &>/dev/null       || need_install+=("iproute2")

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

    # Preserve a single, plain existing listener on ordinary reruns. Do not
    # guess how to collapse multiple listeners or address/TLS-specific syntax.
    local default_port=51938 existing_port=''
    if [[ -s /etc/squid/passwd && -f /etc/squid/squid.conf ]]; then
        existing_port=$(awk '$1=="http_port" {count++; if(NF==2 && $2 ~ /^[0-9]+$/) value=$2; else bad=1} END {if(count==1 && !bad) print value}' /etc/squid/squid.conf)
        [[ -n "$existing_port" ]] || { log_error '已有监听配置复杂或缺失，需要先审阅；未修改端口或凭据。'; return 3; }
        default_port="$existing_port"
    fi
    read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 请输入代理监听端口 (默认: ${default_port}): ${COLOR_RESET}")" input_port
    PROXY_PORT="${input_port:-$default_port}"

    [[ "$PROXY_PORT" =~ ^[0-9]{1,5}$ ]] && (( 10#$PROXY_PORT > 0 && 10#$PROXY_PORT <= 65535 )) || { log_error '端口无效'; return 2; }
    if [[ -s /etc/squid/passwd && "${ROTATE_CREDENTIALS:-0}" != 1 ]]; then
        PRESERVE_CREDENTIALS=1
        PROXY_USER='(保留现有用户)'
        PROXY_PASS='(保留现有凭据，不回显)'
        log_info '保留已有认证文件；轮换需显式 --rotate-credentials。'
        return
    fi
    PRESERVE_CREDENTIALS=0
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

    local SQUID_CONF="${SQUID_CANDIDATE:-/etc/squid/squid.conf}"
    local PASSWD_FILE="/etc/squid/passwd"

    if [[ "$PRESERVE_CREDENTIALS" != 1 ]]; then
        [[ "$PROXY_USER" =~ ^[A-Za-z0-9._-]+$ ]] || { log_error '用户名无效'; return 2; }
        printf '%s\n' "$PROXY_PASS" | htpasswd -ic "$PASSWD_CANDIDATE" "$PROXY_USER"
        chown root:proxy "$PASSWD_CANDIDATE"
        chmod 640 "$PASSWD_CANDIDATE"
    fi

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
    if ! squid -k parse -f "${SQUID_CANDIDATE:-/etc/squid/squid.conf}"; then
        log_error "Squid 配置语法无效。"
        return 1
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

    local deadline=$((SECONDS+20))
    until systemctl is-active --quiet squid && ss -H -ltn "sport = :${PROXY_PORT}" | grep -q .; do
        if (( SECONDS >= deadline )); then
            log_error "Squid 未在限定时间内监听端口 ${PROXY_PORT}。"
            return 1
        fi
        sleep 0.1
    done
    log_success "Squid 服务已运行，端口 ${PROXY_PORT} 已就绪。"
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
    lock_operation
    install_dependencies
    interactive_config
    mkdir -p /etc/squid
    [[ ! -L /etc/squid/squid.conf && ! -L /etc/squid/passwd ]] || { log_error '拒绝替换符号链接'; return 1; }
    local work was_active=0 was_enabled=0 result=0
    work=$(mktemp -d /etc/squid/.lazycat-operation.XXXXXX)
    chmod 700 "$work"
    [[ ! -f /etc/squid/squid.conf ]] || cp -p /etc/squid/squid.conf "$work/config.before"
    [[ ! -f /etc/squid/passwd ]] || cp -p /etc/squid/passwd "$work/passwd.before"
    systemctl is-active --quiet squid && was_active=1
    systemctl is-enabled --quiet squid && was_enabled=1
    SQUID_CANDIDATE="$work/config.after"
    PASSWD_CANDIDATE="$work/passwd.after"
    write_squid_config
    validate_config
    if [[ "$PRESERVE_CREDENTIALS" == 1 ]] && cmp -s "$SQUID_CANDIDATE" /etc/squid/squid.conf; then
        rm -rf "$work"
        log_success '配置及凭据未变化，不重启服务。'
        return
    fi
    printf 'prepared\n' > "$work/status"
    set +e
    (
        set -e
        if [[ "$PRESERVE_CREDENTIALS" != 1 ]]; then mv "$PASSWD_CANDIDATE" /etc/squid/passwd; fi
        chmod 644 "$SQUID_CANDIDATE"
        mv "$SQUID_CANDIDATE" /etc/squid/squid.conf
        systemctl restart squid
        systemctl enable squid
        verify_deployment
    )
    result=$?
    set -e
    if [[ "$result" != 0 ]]; then
        if [[ -f "$work/config.before" ]]; then cp -p "$work/config.before" /etc/squid/squid.conf; else rm -f /etc/squid/squid.conf; fi
        if [[ -f "$work/passwd.before" ]]; then cp -p "$work/passwd.before" /etc/squid/passwd; else rm -f /etc/squid/passwd; fi
        if [[ "$was_active" == 1 ]]; then systemctl restart squid || log_error '恢复服务失败'; else systemctl stop squid; fi
        if [[ "$was_enabled" == 0 ]]; then systemctl disable squid; fi
        printf 'rollback-attempted\n' > "$work/status"
        log_error "应用失败，备份与恢复记录: $work"
        return 1
    fi
    printf 'committed\n' > "$work/status"
    log_info "配置与凭据备份: $work"
    if [[ "$PRESERVE_CREDENTIALS" != 1 ]]; then print_result; else log_success "代理配置完成，旧凭据保留。"; fi
}

ROTATE_CREDENTIALS=0
if [[ "${1:-}" == --rotate-credentials ]]; then ROTATE_CREDENTIALS=1; shift; fi
[[ $# == 0 ]] || { echo '用法：setup_squid_proxy.sh [--rotate-credentials]' >&2; exit 2; }
main "$@"
