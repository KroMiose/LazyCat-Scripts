#!/bin/bash

# ==============================================================================
# 脚本名称: setup_docker_nopasswd.sh
# 功    能: 将当前用户添加到 docker 用户组，以实现免 sudo 运行 Docker 命令。
# 适用系统: 任何已安装 Docker 并使用 systemd 的主流 Linux 发行版。
# 使用方法: sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/linux/setup_docker_nopasswd.sh)"
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

# --- 安全与环境检查 ---
check_privileges() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 'sudo' 来运行此脚本。"
        exit 1
    fi

    if [ -z "$SUDO_USER" ] || [ "$SUDO_USER" == "root" ]; then
        log_error "无法确定普通用户身份或您正直接以 root 登录。"
        log_error "请使用 'sudo -u <your_user> bash -c \"...\"' 或从一个普通用户会话使用 'sudo' 运行。"
        exit 1
    fi
    REAL_USER="$SUDO_USER"
}

# --- 主逻辑 ---
main() {
    log_info "欢迎使用 Docker 免 sudo 配置脚本！"
    log_info "本脚本将尝试把用户 '$REAL_USER' 添加到 'docker' 用户组。"

    # 1. 身份检查
    check_privileges

    # 2. 检查 docker 组是否存在
    if ! getent group docker >/dev/null; then
        log_error "系统中未找到 'docker' 用户组。"
        log_error "请确认您是否已正确安装 Docker。"
        exit 1
    fi
    log_info "'docker' 用户组存在，继续操作。"

    # 3. 检查用户是否已在 docker 组中
    if id -nG "$REAL_USER" | grep -qw "docker"; then
        log_success "用户 '$REAL_USER' 已经是 'docker' 用户组的成员，无需任何操作。"
    else
        log_info "用户 '$REAL_USER' 不在 'docker' 组中，正在为您添加..."
        # 将用户添加到 docker 组
        if usermod -aG docker "$REAL_USER"; then
            log_success "已成功将用户 '$REAL_USER' 添加到 'docker' 组！"
        else
            log_error "将用户添加到 'docker' 组失败！"
            exit 1
        fi
    fi

    # 4. 显示重要提示
    echo -e "\n${COLOR_YELLOW}========================= 重要提示 ========================="
    echo -e "为了使组权限变更完全生效，您必须进行以下操作之一："
    echo -e "  1. 完全注销当前用户，然后重新登录。"
    echo -e "  2. 重新启动您的计算机。"
    echo -e "仅仅关闭和重新打开终端窗口是 ${COLOR_RED}无效的${COLOR_YELLOW}！"
    echo -e "操作完成后，您应该就可以直接使用 \`docker\` 命令了。"
    echo -e "==========================================================${COLOR_RESET}\n"
}

main "$@"
