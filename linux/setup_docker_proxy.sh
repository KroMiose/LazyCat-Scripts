#!/bin/bash

# ==============================================================================
# 脚本名称: setup_docker_proxy.sh
# 功    能: 为 Docker 守护进程配置或移除 HTTP/HTTPS 代理。
#           这会影响 'docker pull', 'docker build' 等网络操作。
# 适用系统: 使用 systemd 的 Linux 系统 (例如 Debian, Ubuntu, CentOS, Fedora)
# 使用方法: sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/linux/setup_docker_proxy.sh)"
# ==============================================================================

# --- 核心函数库和颜色定义 ---
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_RED="\033[31m"
COLOR_RESET="\033[0m"

log_info() {
    echo -e "${COLOR_BLUE}INFO: $1${COLOR_RESET}"
}
log_success() {
    echo -e "${COLOR_GREEN}SUCCESS: $1${COLOR_RESET}"
}
log_warn() {
    echo -e "${COLOR_YELLOW}WARN: $1${COLOR_RESET}"
}
log_error() {
    echo -e "${COLOR_RED}ERROR: $1${COLOR_RESET}" >&2
}

# --- 检查和函数定义 ---

# 检查是否以 root 身份运行
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本必须以 root 或 sudo 身份运行！"
        exit 1
    fi
}

# 检查 systemd 是否存在
check_systemd() {
    if ! [ -d /run/systemd/system ]; then
        log_error "此脚本仅支持使用 systemd 的 Linux 系统。"
        exit 1
    fi
    if ! command -v docker &>/dev/null; then
        log_error "未找到 Docker。请先安装 Docker 再运行此脚本。"
        exit 1
    fi
}

# 提示重启 Docker
prompt_restart_docker() {
    echo ""
    log_info "为了使更改生效，需要重载 systemd 并重启 Docker 服务。"
    read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 是否现在为您执行 'systemctl daemon-reload && systemctl restart docker'？ (Y/n): ${COLOR_RESET}")" confirm_restart
    if [[ ! "$confirm_restart" =~ ^[Nn]$ ]]; then
        log_info "⏳ 正在重载 daemon 并重启 Docker..."
        if systemctl daemon-reload && systemctl restart docker; then
            log_success "✅ Docker 已成功重启！"
        else
            log_error "❌ Docker 重启失败。请手动运行以下命令进行检查和重启："
            log_error "  sudo systemctl daemon-reload"
            log_error "  sudo systemctl restart docker"
        fi
    else
        log_warn "请稍后手动运行以下命令以应用更改:"
        log_warn "  sudo systemctl daemon-reload"
        log_warn "  sudo systemctl restart docker"
    fi
}

# 配置代理的函数
configure_docker_proxy() {
    log_info "--- 开始配置 Docker 代理 ---"

    # --- 尝试从环境变量中获取现有代理配置 ---
    local EXISTING_PROXY=""
    if [ -n "$http_proxy" ]; then
        EXISTING_PROXY="$http_proxy"
    elif [ -n "$https_proxy" ]; then
        EXISTING_PROXY="$https_proxy"
    elif [ -n "$all_proxy" ]; then
        EXISTING_PROXY="$all_proxy"
    elif [ -n "$HTTP_PROXY" ]; then
        EXISTING_PROXY="$HTTP_PROXY"
    elif [ -n "$HTTPS_PROXY" ]; then
        EXISTING_PROXY="$HTTPS_PROXY"
    elif [ -n "$ALL_PROXY" ]; then
        EXISTING_PROXY="$ALL_PROXY"
    fi

    local DEFAULT_HOST="127.0.0.1"
    local DEFAULT_PORT="7890"

    if [ -n "$EXISTING_PROXY" ]; then
        log_info "🔍 检测到现有代理环境变量: $EXISTING_PROXY"
        local PROXY_NO_PROTOCOL=$(echo "$EXISTING_PROXY" | sed -E 's_.*://__; s_/$__')
        local PROXY_HOST_PORT=$(echo "$PROXY_NO_PROTOCOL" | sed -E 's/.*@//')
        DEFAULT_HOST=$(echo "$PROXY_HOST_PORT" | awk -F: '{print $1}')
        DEFAULT_PORT=$(echo "$PROXY_HOST_PORT" | awk -F: '{print $2}')
        log_info "  -> 将使用 Host: $DEFAULT_HOST, Port: $DEFAULT_PORT 作为默认值。"
    fi

    read -p "  -> 请输入代理主机 (默认: ${DEFAULT_HOST}): " proxy_host
    proxy_host=${proxy_host:-${DEFAULT_HOST}}
    read -p "  -> 请输入代理端口 (默认: ${DEFAULT_PORT}): " proxy_port
    proxy_port=${proxy_port:-${DEFAULT_PORT}}

    read -p "  -> 请输入 NO_PROXY 列表 (多个用逗号隔开, 默认: localhost,127.0.0.1): " no_proxy_input
    local no_proxy=${no_proxy_input:-"localhost,127.0.0.1"}

    local DOCKER_CONF_DIR="/etc/systemd/system/docker.service.d"
    local PROXY_CONF_FILE="$DOCKER_CONF_DIR/http-proxy.conf"

    log_info "🔧 正在创建 systemd drop-in 目录: $DOCKER_CONF_DIR"
    mkdir -p "$DOCKER_CONF_DIR"

    # 使用 cat 和 EOF 创建配置块，确保引号正确处理
    log_info "✍️  正在写入代理配置文件: $PROXY_CONF_FILE"
    cat >"$PROXY_CONF_FILE" <<EOF
[Service]
Environment="HTTP_PROXY=http://${proxy_host}:${proxy_port}"
Environment="HTTPS_PROXY=http://${proxy_host}:${proxy_port}"
Environment="NO_PROXY=${no_proxy}"
EOF

    log_success "✅ Docker 代理配置文件已成功创建/更新。"
    prompt_restart_docker
}

# 移除代理的函数
remove_docker_proxy() {
    log_info "--- 开始移除 Docker 代理 ---"
    local DOCKER_CONF_DIR="/etc/systemd/system/docker.service.d"
    local PROXY_CONF_FILE="$DOCKER_CONF_DIR/http-proxy.conf"

    if [ -f "$PROXY_CONF_FILE" ]; then
        log_info "🗑️  正在删除代理配置文件: $PROXY_CONF_FILE"
        rm -f "$PROXY_CONF_FILE"
        log_success "✅ Docker 代理配置文件已移除。"

        # 检查目录是否为空，如果为空则删除
        if [ -z "$(ls -A "$DOCKER_CONF_DIR" 2>/dev/null)" ]; then
            log_info "💨 配置目录为空，正在移除: $DOCKER_CONF_DIR"
            rmdir "$DOCKER_CONF_DIR"
        fi
        prompt_restart_docker
    else
        log_success "🤷‍♀️ 未找到 Docker 代理配置文件，无需操作。"
    fi
}

# --- 主逻辑 ---
main() {
    check_root
    check_systemd

    log_info "--- Docker 代理配置工具 ---"
    echo ""
    PS3="👉 请选择您要执行的操作: "
    select choice in "配置/更新 Docker 代理" "移除 Docker 代理" "退出"; do
        case $choice in
        "配置/更新 Docker 代理")
            configure_docker_proxy
            break
            ;;
        "移除 Docker 代理")
            remove_docker_proxy
            break
            ;;
        "退出")
            log_info "操作已取消。"
            exit 0
            ;;
        *)
            log_warn "无效的选项，请重新输入。"
            ;;
        esac
    done
}

main "$@"
