#!/bin/bash

# ==============================================================================
# 脚本名称: setup_squid_proxy.sh
# 功    能: 在 Linux 服务器上一键部署带 Basic Auth 认证的 Squid HTTP/HTTPS 代理。
#           自动生成随机账号密码、写入匿名化配置，并输出可直接使用的代理 URL。
# 适用系统: 基于 Debian/Ubuntu 的 Linux 系统（使用 systemd）
# 仓库入口: sudo bash linux/setup_squid_proxy.sh；服务与凭据影响见 linux/README.md。
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

squid_copy() {
    cp --preserve=mode,ownership,timestamps,xattr -- "$1" "$2"
}

squid_check_directory() {
    local mode
    [[ ! -L /etc && ! -L /etc/squid ]] || { log_error 'Squid 路径包含符号链接，需要先审阅'; return 3; }
    [[ -e /etc/squid ]] || return 0
    [[ -d /etc/squid && "$(stat -c %u /etc/squid)" == 0 ]] || return 3
    mode=$(stat -c %a /etc/squid)
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0022) == 0 )) || { log_error 'Squid 目录允许其他身份写入，不能建立可信恢复记录'; return 3; }
}

squid_capture() {
    local target="$1" snapshot="$2"
    [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] || { log_error '配置或认证目标不是普通文件，未修改。'; return 3; }
    if [[ -f "$target" ]]; then
        LC_ALL=C stat -c '%d:%i:%z' -- "$target" > "${snapshot}.revision"
        squid_copy "$target" "$snapshot"
    fi
    squid_check_original "$target" "$snapshot"
}

squid_check_original() {
    local target="$1" snapshot="$2"
    if [[ -f "$snapshot" ]]; then
        [[ -f "$target" && ! -L "$target" && "$(LC_ALL=C stat -c '%d:%i:%z' -- "$target")" == "$(cat "${snapshot}.revision")" ]] &&
            cmp -s "$target" "$snapshot" && return 0
    elif [[ ! -e "$target" && ! -L "$target" ]]; then
        return 0
    fi
    log_error '配置或凭据被并发修改，已停止；用户修改与备份保留。'
    return 3
}

# Canonical GNU tar stream includes content, mode, owner, mtime, ACLs and all
# readable xattrs. Normalize only archive names and access/change timestamps.
# This permits recovery after rename even when its subsequent journal write was
# interrupted. Private contents flow only through a pipe to SHA-256.
squid_fingerprint() {
    local target="$1"
    if [[ ! -e "$target" && ! -L "$target" ]]; then printf 'absent\n'; return; fi
    [[ -f "$target" && ! -L "$target" ]] || return 3
    tar --format=pax --numeric-owner --acls --xattrs --xattrs-include='*' \
        --pax-option=exthdr.name=resource.pax,delete=atime,delete=ctime \
        --transform='s|.*|resource|' -cf - -C "${target%/*}" -- "${target##*/}" | sha256sum | awk '{print $1}'
}

squid_record() {
    local directory="$1" name="$2" value="$3" temporary
    temporary=$(mktemp "$directory/.record.XXXXXX") || return 1
    printf '%s\n' "$value" > "$temporary" || return 1
    mv "$temporary" "$directory/$name"
}

squid_pending() {
    local directory status
    for directory in /etc/squid/.lazycat-operation.*; do
        [[ -d "$directory" && ! -L "$directory" ]] || continue
        [[ -f "$directory/status" && ! -L "$directory/status" ]] || continue
        IFS= read -r status < "$directory/status" || return 3
        case "$status" in
            prepared|restoring|recovery-conflict)
                log_error "存在未完成操作：$directory；请先运行 --recover <操作目录>。旧格式无法自动恢复时需审阅。"
                return 3 ;;
        esac
    done
}

squid_recover_operation() {
    local work="$1" resource target before expected current status active enabled port deadline record
    squid_check_directory
    [[ "${work%/*}" == /etc/squid && "${work##*/}" == .lazycat-operation.* && ! -L /etc/squid && ! -L "$work" ]] || return 3
    [[ "$(stat -c '%u:%a' -- "$work")" == 0:700 ]] || { log_error '恢复目录归属或权限无效'; return 3; }
    for record in journal-version status service.active service.enabled config.before-fingerprint config.after-fingerprint passwd.before-fingerprint passwd.after-fingerprint; do
        [[ -f "$work/$record" && ! -L "$work/$record" && "$(stat -c %u -- "$work/$record")" == 0 ]] || { log_error '恢复记录缺失或格式不支持，未修改文件'; return 3; }
    done
    [[ "$(cat "$work/journal-version")" == 1 ]] || return 3
    IFS= read -r status < "$work/status"
    case "$status" in prepared|restoring|recovery-conflict|rolled-back) ;; *) log_error '该操作不是可恢复的中断记录'; return 3 ;; esac
    active=$(cat "$work/service.active"); enabled=$(cat "$work/service.enabled")
    case "$active" in active|inactive) ;; *) return 3 ;; esac
    case "$enabled" in enabled|disabled|enabled-runtime) ;; *) return 3 ;; esac
    # Validate both resources before touching either. A copied backup alone is
    # not evidence: compare its full recorded fingerprint and the live file.
    for resource in config passwd; do
        target=/etc/squid/passwd
        [[ "$resource" != config ]] || target=/etc/squid/squid.conf
        before=$(cat "$work/$resource.before-fingerprint")
        expected=$(cat "$work/$resource.after-fingerprint")
        [[ "$before" == absent || "$before" =~ ^[a-f0-9]{64}$ ]] || return 3
        [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || return 3
        [[ "$(squid_fingerprint "$work/$resource.before")" == "$before" && "$(squid_fingerprint "$work/$resource.expected")" == "$expected" ]] || { log_error '备份或候选已改变，未恢复'; return 3; }
        current=$(squid_fingerprint "$target") || return 3
        if [[ "$current" != "$before" && ( "$status" == rolled-back || "$current" != "$expected" ) ]]; then
            squid_record "$work" status recovery-conflict
            log_error "文件或属性不匹配，未覆盖任一文件或再次切换服务：$work"
            return 3
        fi
        if [[ "$current" != "$before" && -e "$work/$resource.published-revision" ]]; then
            [[ -f "$work/$resource.published-revision" && ! -L "$work/$resource.published-revision" && "$(stat -c '%d:%i:%z' -- "$target")" == "$(cat "$work/$resource.published-revision")" ]] || { squid_record "$work" status recovery-conflict; return 3; }
        fi
    done
    if [[ "$status" == rolled-back ]]; then
        [[ "$(systemctl show squid --property=ActiveState --value)" == "$active" && "$(systemctl show squid --property=UnitFileState --value)" == "$enabled" ]] || return 3
        log_success '已恢复，文件和服务状态未变化。'
        return
    fi
    squid_record "$work" status restoring
    for resource in config passwd; do
        target=/etc/squid/passwd
        [[ "$resource" != config ]] || target=/etc/squid/squid.conf
        before=$(cat "$work/$resource.before-fingerprint")
        current=$(squid_fingerprint "$target") || return 3
        [[ "$current" != "$before" ]] || continue
        [[ "$current" == "$(cat "$work/$resource.after-fingerprint")" ]] || { squid_record "$work" status recovery-conflict; return 3; }
        if [[ "$before" == absent ]]; then
            rm -- "$target"
        else
            record=$(mktemp "${target}.lazycat-restore.XXXXXX")
            squid_copy "$work/$resource.before" "$record"
            # Recheck after staging, not merely before a potentially slow copy.
            [[ "$(squid_fingerprint "$target")" == "$current" ]] || { rm -f "$record"; squid_record "$work" status recovery-conflict; return 3; }
            mv "$record" "$target"
        fi
    done
    case "$enabled" in
        enabled) systemctl enable squid ;;
        disabled) systemctl disable squid ;;
        enabled-runtime) systemctl disable squid; systemctl enable --runtime squid ;;
    esac
    if [[ "$active" == active ]]; then
        systemctl restart squid
        port=$(awk '$1=="http_port" && NF==2 && $2~/^[0-9]+$/ {n++;p=$2} END {if(n==1)print p}' /etc/squid/squid.conf)
        deadline=$((SECONDS+20))
        until systemctl is-active --quiet squid && { [[ -z "$port" ]] || ss -H -ltn "sport = :$port" | grep -q .; }; do
            ((SECONDS < deadline)) || return 1
            sleep .1
        done
    else
        systemctl stop squid
    fi
    [[ "$(systemctl show squid --property=ActiveState --value)" == "$active" && "$(systemctl show squid --property=UnitFileState --value)" == "$enabled" ]] || return 1
    squid_record "$work" status rolled-back
    log_success "文件与原服务状态已恢复，备份保留：$work"
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
    squid_check_directory
    squid_pending
    install_dependencies
    (umask 022; mkdir -p /etc/squid)
    squid_check_directory
    [[ ! -L /etc/squid/squid.conf && ! -L /etc/squid/passwd ]] || { log_error '拒绝替换符号链接'; return 1; }
    local work active enabled result=0 recovery_result=0 resource before expected
    work=$(mktemp -d /etc/squid/.lazycat-operation.XXXXXX)
    chmod 700 "$work"
    squid_capture /etc/squid/squid.conf "$work/config.before"
    squid_capture /etc/squid/passwd "$work/passwd.before"
    interactive_config
    active=$(systemctl show squid --property=ActiveState --value)
    enabled=$(systemctl show squid --property=UnitFileState --value)
    case "$active:$enabled" in active:enabled|active:disabled|active:enabled-runtime|inactive:enabled|inactive:disabled|inactive:enabled-runtime) ;; *) log_error '原服务状态需要先审阅，未修改文件'; return 3 ;; esac
    SQUID_CANDIDATE="$work/config.after"
    PASSWD_CANDIDATE="$work/passwd.after"
    [[ ! -f "$work/config.before" ]] || squid_copy "$work/config.before" "$SQUID_CANDIDATE"
    write_squid_config
    if [[ "$PRESERVE_CREDENTIALS" != 1 && -f "$work/passwd.before" ]]; then
        cp --attributes-only --preserve=mode,ownership,timestamps,xattr -- "$work/passwd.before" "$PASSWD_CANDIDATE"
    fi
    validate_config
    squid_check_original /etc/squid/squid.conf "$work/config.before"
    squid_check_original /etc/squid/passwd "$work/passwd.before"
    if [[ "$PRESERVE_CREDENTIALS" == 1 ]] && cmp -s "$SQUID_CANDIDATE" /etc/squid/squid.conf; then
        rm -rf "$work"
        log_success '配置及凭据未变化，不重启服务。'
        return
    fi
    [[ -f "$work/config.before" ]] || chmod 644 "$SQUID_CANDIDATE"
    squid_copy "$SQUID_CANDIDATE" "$work/config.expected"
    if [[ "$PRESERVE_CREDENTIALS" != 1 ]]; then squid_copy "$PASSWD_CANDIDATE" "$work/passwd.expected"; else squid_copy "$work/passwd.before" "$work/passwd.expected"; fi
    for resource in config passwd; do
        before=$(squid_fingerprint "$work/$resource.before")
        expected=$(squid_fingerprint "$work/$resource.expected")
        squid_record "$work" "$resource.before-fingerprint" "$before"
        squid_record "$work" "$resource.after-fingerprint" "$expected"
    done
    squid_record "$work" service.active "$active"
    squid_record "$work" service.enabled "$enabled"
    squid_record "$work" journal-version 1
    squid_record "$work" status prepared
    squid_check_original /etc/squid/squid.conf "$work/config.before"
    squid_check_original /etc/squid/passwd "$work/passwd.before"
    set +e
    (
        set -e
        if [[ "$PRESERVE_CREDENTIALS" != 1 ]]; then
            mv "$PASSWD_CANDIDATE" /etc/squid/passwd
            LC_ALL=C stat -c '%d:%i:%z' /etc/squid/passwd > "$work/passwd.published-revision"
        fi
        [[ -f "$work/config.before" ]] || chmod 644 "$SQUID_CANDIDATE"
        mv "$SQUID_CANDIDATE" /etc/squid/squid.conf
        LC_ALL=C stat -c '%d:%i:%z' /etc/squid/squid.conf > "$work/config.published-revision"
        systemctl restart squid
        systemctl enable squid
        verify_deployment
    )
    result=$?
    set -e
    if [[ "$result" != 0 ]]; then
        set +e
        (set -e; squid_recover_operation "$work")
        recovery_result=$?
        set -e
        log_error "应用失败；恢复结果=$recovery_result，记录：$work"
        [[ "$recovery_result" != 3 ]] || return 3
        return 1
    fi
    printf 'committed\n' > "$work/status"
    log_info "配置与凭据备份: $work"
    if [[ "$PRESERVE_CREDENTIALS" != 1 ]]; then print_result; else log_success "代理配置完成，旧凭据保留。"; fi
}

if [[ "${1:-}" == --recover ]]; then
    [[ $# == 2 ]] || { echo '--recover <操作目录>' >&2; exit 2; }
    check_root
    check_systemd
    lock_operation
    squid_recover_operation "$2"
    exit
fi
ROTATE_CREDENTIALS=0
if [[ "${1:-}" == --rotate-credentials ]]; then ROTATE_CREDENTIALS=1; shift; fi
[[ $# == 0 ]] || { echo '用法：setup_squid_proxy.sh [--rotate-credentials | --recover <操作目录>]' >&2; exit 2; }
main "$@"
