#!/bin/bash

# ==============================================================================
# 脚本名称: setup_python_env.sh
# 功    能: 快速搭建 Python 开发工具环境。
#           本脚本将为您通过 apt 安装 poetry, 并通过官方脚本安装 pdm。
#           脚本内置了网络代理和 PyPI 镜像的配置向导。
# 适用系统: 基于 Debian/Ubuntu 的系统。
# 使用方法: sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/linux/setup_python_env.sh)"
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
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 'sudo' 来运行此脚本。"
    exit 1
fi

if [ -z "$SUDO_USER" ]; then
    log_error "无法确定普通用户身份。请使用 'sudo' 运行。"
    exit 1
fi
REAL_USER="$SUDO_USER"
USER_SHELL=$(getent passwd "$REAL_USER" | cut -d: -f7)
if [ -z "$USER_SHELL" ] || [ ! -x "$USER_SHELL" ]; then
    log_warn "无法确定用户 '$REAL_USER' 的有效默认 Shell，将回退使用 /bin/bash。"
    USER_SHELL="/bin/bash"
fi

# --- 核心辅助函数 ---
# 在普通用户环境中执行命令，并传递网络配置
run_as_user() {
    local env_vars="$1"
    local script_to_run="$2"
    # 使用由 getent 命令获取到的用户真实 Shell 来执行命令，确保环境一致性
    # 例如，这能让 pdm 的安装脚本正确地识别到 .zshrc 并修改它
    sudo -i -u "$REAL_USER" "$USER_SHELL" <<<"set -e; export ${env_vars}; ${script_to_run}"
}

# --- 业务逻辑函数 ---

install_system_dependencies() {
    log_info "正在更新软件包列表并安装基础依赖 (python3-pip, venv, git, curl, poetry)..."
    # 使用在 network_setup 中配置的代理
    env ${PROXY_ENV} apt-get update
    # python3-poetry 会将 poetry 安装到系统路径
    env ${PROXY_ENV} apt-get install -y python3-pip python3-venv git curl python3-poetry
    log_success "基础依赖及 Poetry 安装完毕。"
}

network_setup() {
    # 这些变量将在全局范围内被修改
    PROXY_ENV=""
    PIP_ENV=""

    read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 您是否需要通过代理服务器访问网络？ (y/N): ${COLOR_RESET}")" use_proxy
    if [[ "$use_proxy" =~ ^[Yy]$ ]]; then
        read -p "  -> 请输入代理主机 (例如: 127.0.0.1): " proxy_host
        read -p "  -> 请输入代理端口 (例如: 7890): " proxy_port
        if [[ -n "$proxy_host" && -n "$proxy_port" ]]; then
            local proxy_url="http://${proxy_host}:${proxy_port}"
            log_info "将为本次执行设置网络代理: ${proxy_url}"
            PROXY_ENV="http_proxy=${proxy_url} https_proxy=${proxy_url}"
        else
            log_warn "代理主机或端口为空，跳过代理设置。"
        fi
    fi

    read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 是否使用 PyPI 镜像加速下载？(推荐)(Y/n): ${COLOR_RESET}")" use_mirror
    if [[ ! "$use_mirror" =~ ^[Nn]$ ]]; then
        local mirror_url="https://pypi.tuna.tsinghua.edu.cn/simple"
        log_info "将使用清华大学 PyPI 镜像源: ${mirror_url}"
        PIP_ENV="PIP_INDEX_URL=${mirror_url}"
    fi
}

install_pdm() {
    local env_exports="${PROXY_ENV} ${PIP_ENV}"

    log_info "正在为用户 '$REAL_USER' 下载并安装 pdm..."
    log_info "将使用 PDM 官方推荐的安装脚本。"

    local pdm_install_script="curl -sSL https://raw.githubusercontent.com/pdm-project/pdm/main/install-pdm.py | python3 -"

    if run_as_user "$env_exports" "$pdm_install_script"; then
        log_success "'pdm' 的二进制文件已成功安装到 ~/.local/bin。"
    else
        log_error "'pdm' 安装失败。请检查网络连接或代理设置。"
        return 1
    fi

    log_info "正在确保 ~/.local/bin 目录在您的 Shell 路径中..."
    local path_setup_script=$(
        cat <<'EOF'
# This script runs inside the user's shell (e.g., zsh), so $SHELL and $HOME are correct.
if [[ "$SHELL" == *zsh ]]; then
    CONFIG_FILE="$HOME/.zshrc"
elif [[ "$SHELL" == *bash ]]; then
    CONFIG_FILE="$HOME/.bashrc"
else
    # A safe fallback for other shells like dash, sh etc. that read .profile
    CONFIG_FILE="$HOME/.profile"
fi

# Ensure the user's local bin and the config file exist
mkdir -p "$HOME/.local/bin"
touch "$CONFIG_FILE"

# Define the configuration block with unique markers
PATH_BLOCK=$(cat <<'EOM_BLOCK'
# --- LAZYCAT-LOCAL-BIN-START ---
# Added by LazyCat-Scripts to ensure local binaries are in PATH
export PATH="$HOME/.local/bin:$PATH"
# --- LAZYCAT-LOCAL-BIN-END ---
EOM_BLOCK
)

# Idempotently update the configuration file by removing the old block first
if grep -qF -- "# --- LAZYCAT-LOCAL-BIN-START ---" "$CONFIG_FILE"; then
    # Use awk to print all lines NOT between the markers
    awk '
        BEGIN {p=0}
        /# --- LAZYCAT-LOCAL-BIN-START ---/ {p=1; next}
        /# --- LAZYCAT-LOCAL-BIN-END ---/ {p=0; next}
        !p {print}
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo "INFO: 已移除旧的路径配置，准备更新..."
fi

# Append the new block to the file
printf "\n%s\n" "$PATH_BLOCK" >> "$CONFIG_FILE"

echo "SUCCESS: 已将 '$HOME/.local/bin' 路径配置到 ${CONFIG_FILE} 中。"
EOF
    )
    # Run the path setup script as the actual user in their own shell
    if run_as_user "" "$path_setup_script"; then
        log_success "Shell 路径配置成功！请重启终端以使更改生效。"
    else
        log_error "自动配置 Shell 路径失败。"
        log_warn "您可能需要手动将 '$HOME/.local/bin' 添加到您的 PATH 中。"
        return 1
    fi

    return 0
}

show_summary() {
    echo -e "\n${COLOR_GREEN}========================================================"
    echo -e "      🎉 Python 工具环境配置完成! 🎉"
    echo -e "--------------------------------------------------------${COLOR_RESET}"
    echo -e "已为您安装好 poetry 和 pdm。"
    echo -e "为确保所有更改完全生效, 请执行以下操作:"
    echo -e "\n  1. ${COLOR_YELLOW}关闭当前所有的终端窗口。${COLOR_RESET}"
    echo -e "  2. ${COLOR_YELLOW}重新打开一个新的终端。${COLOR_RESET}"
    echo -e "\n然后您就可以在新的终端中使用 poetry 和 pdm 命令了。"
    echo -e "${COLOR_GREEN}========================================================${COLOR_RESET}\n"
}

# --- 主逻辑 ---
main() {
    log_info "欢迎使用 Python 工具环境配置向导！"
    log_info "本脚本将为您安装 poetry 和 pdm。"

    # 优先进行网络配置，以便后续所有下载操作都能使用
    network_setup

    install_system_dependencies

    if ! install_pdm; then
        log_error "环境配置过程中发生错误，脚本已中止。"
        exit 1
    fi

    show_summary
}

main "$@"
