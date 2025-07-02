#!/bin/bash

# ==============================================================================
# 脚本名称: setup_python_env.sh
# 功    能: 快速搭建功能强大的 Python 开发环境。
#           本脚本将为您安装 pyenv, poetry, pdm, 和 uv。
#           - pyenv: 用于管理和隔离不同的 Python 版本。
#           - poetry & pdm: 现代化的 Python 依赖管理和打包工具。
#           - uv: 由 Rust 编写的极速 Python 包安装器和解析器。
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
    USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    USER_SHELL=$(getent passwd "$REAL_USER" | cut -d: -f7)
    if [ -z "$USER_SHELL" ] || [ ! -x "$USER_SHELL" ]; then
        log_warn "无法确定用户 '$REAL_USER' 的有效默认 Shell，将回退使用 /bin/bash。"
        USER_SHELL="/bin/bash"
    fi
}

# --- 核心辅助函数 ---
# 在普通用户环境中执行命令，并传递必要的环境变量
# 使用 sudo -i 来模拟登录，这会加载 .profile, .zprofile 等配置文件，确保 PATH 生效
run_as_user() {
    local env_vars="$1"
    local script_to_run="$2"
    sudo -i -u "$REAL_USER" bash <<EOF
set -e
export ${env_vars}
${script_to_run}
EOF
}

# --- 业务逻辑函数 ---

install_build_dependencies() {
    log_info "正在更新软件包列表并安装 Python 编译依赖和基础工具..."
    # 使用在 network_setup 中配置的代理
    env ${PROXY_ENV} apt-get update
    # 安装 pyenv 的编译依赖以及其他基础工具
    env ${PROXY_ENV} apt-get install -y \
        build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev \
        libsqlite3-dev wget curl llvm libncurses5-dev xz-utils tk-dev \
        libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev python3-pip \
        python3-venv git
    log_success "编译依赖及基础工具安装完毕。"
}

network_setup() {
    # 这些变量将在全局范围内被修改
    PROXY_ENV=""
    PIP_ENV=""

    read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 您是否需要通过代理服务器访问网络？ (y/N): ${COLOR_RESET}")" use_proxy
    if [[ "$use_proxy" =~ ^[Yy]$ ]]; then
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
            # 移除协议头和尾部斜杠
            local PROXY_NO_PROTOCOL=$(echo "$EXISTING_PROXY" | sed -E 's_.*://__; s_/$__')
            # 从 user:pass@host:port 中提取 host:port
            local PROXY_HOST_PORT=$(echo "$PROXY_NO_PROTOCOL" | sed -E 's/.*@//')
            DEFAULT_HOST=$(echo "$PROXY_HOST_PORT" | awk -F: '{print $1}')
            DEFAULT_PORT=$(echo "$PROXY_HOST_PORT" | awk -F: '{print $2}')
            log_info "检测到现有代理: $EXISTING_PROXY, 将其作为默认值。"
        fi

        read -p "  -> 请输入代理主机 (默认: ${DEFAULT_HOST}): " proxy_host
        proxy_host=${proxy_host:-${DEFAULT_HOST}}
        read -p "  -> 请输入代理端口 (默认: ${DEFAULT_PORT}): " proxy_port
        proxy_port=${proxy_port:-${DEFAULT_PORT}}

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

# 通用的 Shell 配置注入函数
# 负责将配置代码块幂等地添加到用户的 Shell 配置文件中
inject_shell_config() {
    local -r real_user="$1"
    local -r user_home="$2"
    local -r user_shell="$3"
    local -r block_identifier="$4"
    local -r config_block="$5"

    local config_file
    if [[ "$user_shell" == *zsh ]]; then
        config_file="$user_home/.zshrc"
    elif [[ "$user_shell" == *bash ]]; then
        # 同时检查 .bashrc 和 .profile，优先 .bashrc
        if [ -f "$user_home/.bashrc" ]; then
            config_file="$user_home/.bashrc"
        else
            config_file="$user_home/.profile"
        fi
    else
        config_file="$user_home/.profile" # 兜底方案
    fi

    log_info "正在为用户 '$real_user' 配置 Shell 文件: $config_file"

    # 确保配置文件存在
    if ! sudo -u "$real_user" touch "$config_file"; then
        log_error "无法创建或访问配置文件 $config_file。"
        return 1
    fi

    # 使用唯一的标记来确保幂等性
    local -r start_marker="# --- ${block_identifier}-START ---"
    local -r end_marker="# --- ${block_identifier}-END ---"

    # 1. 移除旧的配置块（如果存在）
    # 我们需要在 root 环境下操作，因为 sudo -u 不能直接用于复杂的重定向
    # 所以先读到临时文件，处理完再写回去
    local temp_config
    temp_config=$(mktemp)
    sudo -u "$real_user" cat "$config_file" >"$temp_config"

    if grep -qF -- "$start_marker" "$temp_config"; then
        log_info "检测到旧的 '$block_identifier' 配置，将进行更新..."
        sed -i.bak "/^${start_marker}$/,/^${end_marker}$/d" "$temp_config"
    fi

    # 2. 追加新的配置块
    printf "\n%s\n%s\n%s\n" "$start_marker" "$config_block" "$end_marker" >>"$temp_config"

    # 3. 将更新后的内容写回原文件，并设置正确的所有权
    cat "$temp_config" >"$config_file" # 以 root 身份写入
    chown "${real_user}:${real_user}" "$config_file"
    rm "$temp_config"
    [ -f "${temp_config}.bak" ] && rm "${temp_config}.bak"

    log_success "'$block_identifier' 的 Shell 配置已注入到 $config_file。"
}

install_pyenv() {
    log_info "正在检查 pyenv 安装状态..."
    # pyenv 官方安装脚本 (pyenv.run) 在目标目录 (~/.pyenv) 已存在时会报错退出。
    # 因此，我们在此处检查该目录是否存在，以确保脚本的幂等性。
    if sudo -u "$REAL_USER" [ -d "$USER_HOME/.pyenv" ]; then
        log_info "检测到 '$USER_HOME/.pyenv' 目录，将跳过 pyenv 的下载和安装。"
    else
        log_info "正在为用户 '$REAL_USER' 下载并安装 pyenv..."
        local pyenv_installer="curl -sSL https://pyenv.run | bash"
        if ! run_as_user "$PROXY_ENV" "$pyenv_installer"; then
            log_error "pyenv 安装失败。请检查网络或代理设置。"
            return 1
        fi
        log_success "pyenv 安装成功。"
    fi

    log_info "正在配置 pyenv 的 Shell 环境..."
    local pyenv_config
    pyenv_config=$(
        cat <<'EOF'
# Added by LazyCat-Scripts for Pyenv
export PYENV_ROOT="$HOME/.pyenv"
command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
EOF
    )

    if ! inject_shell_config "$REAL_USER" "$USER_HOME" "$USER_SHELL" "LAZYCAT-PYENV" "$pyenv_config"; then
        log_error "自动配置 pyenv 的 Shell 环境失败。"
        log_warn "您可能需要手动将以下内容添加到您的 Shell 配置文件中:"
        echo "$pyenv_config"
        return 1
    fi

    # 为 pyenv 添加对 ~/.local/bin 的感知，这样它安装的 shims (如 pip) 就能找到 poetry/pdm
    local path_config
    path_config=$(
        cat <<'EOF'
# Added by LazyCat-Scripts to ensure local binaries are in PATH
export PATH="$HOME/.local/bin:$PATH"
EOF
    )

    if ! inject_shell_config "$REAL_USER" "$USER_HOME" "$USER_SHELL" "LAZYCAT-LOCAL-BIN" "$path_config"; then
        log_error "自动配置 ~/.local/bin 路径失败。"
        log_warn "您可能需要手动将 '$USER_HOME/.local/bin' 添加到您的 PATH 中。"
        return 1
    fi

    return 0
}

install_poetry() {
    local env_exports="${PROXY_ENV} ${PIP_ENV}"
    log_info "正在为用户 '$REAL_USER' 下载并安装 poetry..."

    local poetry_install_options=""
    # 基于 https://github.com/python-poetry/install.python-poetry.org 的文档
    # 要安装旧的稳定版 (1.8.x)，我们需要明确指定版本号。
    read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 您希望安装哪个版本的 Poetry? [1] 1.8.x (旧版稳定版) [2] 2.x (最新稳定版) (默认: 1): ${COLOR_RESET}")" poetry_choice

    if [[ "${poetry_choice:-1}" == "2" ]]; then
        log_info "选择安装 Poetry 2.x (最新稳定版)..."
        poetry_install_options="" # 安装脚本默认安装最新稳定版
    else
        # 根据官方 Release，1.8 系列的最后一个版本是 1.8.5
        local legacy_version="1.8.5"
        log_info "选择安装 Poetry 1.8.x (将使用版本: ${legacy_version})..."
        poetry_install_options="--version ${legacy_version}"
    fi

    local poetry_installer="curl -sSL https://install.python-poetry.org | python3 - ${poetry_install_options}"
    if ! run_as_user "$env_exports" "$poetry_installer"; then
        log_error "Poetry 安装失败。请检查网络或代理设置。"
        return 1
    fi
    log_success "Poetry 安装成功，已安装到 $USER_HOME/.local/bin。"

    read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 是否将 Poetry 的虚拟环境固定创建在项目目录中 (.venv)？(推荐)(Y/n): ${COLOR_RESET}")" use_in_project
    if [[ ! "$use_in_project" =~ ^[Nn]$ ]]; then
        log_info "正在为 Poetry 设置 'virtualenvs.in-project' 为 'true'..."
        # 这个命令需要在 pyenv 环境加载后执行，所以我们再次使用 run_as_user
        if run_as_user "" "$USER_HOME/.local/bin/poetry config virtualenvs.in-project true"; then
            log_success "Poetry 配置成功。"
        else
            log_error "Poetry 'virtualenvs.in-project' 配置失败。"
        fi
    fi
    return 0
}

install_pdm() {
    local env_exports="${PROXY_ENV} ${PIP_ENV}"

    log_info "正在为用户 '$REAL_USER' 下载并安装 pdm..."
    log_info "将使用 PDM 官方推荐的安装脚本。"

    local pdm_install_script="curl -sSL https://raw.githubusercontent.com/pdm-project/pdm/main/install-pdm.py | python3 -"

    if run_as_user "$env_exports" "$pdm_install_script"; then
        log_success "'pdm' 的二进制文件已成功安装到 $USER_HOME/.local/bin。"
    else
        log_error "'pdm' 安装失败。请检查网络连接或代理设置。"
        return 1
    fi

    return 0
}

install_uv() {
    local env_exports="${PROXY_ENV}"
    log_info "正在为用户 '$REAL_USER' 下载并安装 uv (极速 Python 包安装器)..."

    # 使用官方推荐的安装脚本
    # 脚本会自动处理 PATH, 安装到 ~/.local/bin
    local uv_installer="curl -LsSf https://astral.sh/uv/install.sh | sh"
    if ! run_as_user "$env_exports" "$uv_installer"; then
        log_error "uv 安装失败。请检查网络或代理设置。"
        return 1
    fi
    log_success "uv 安装成功，已安装到 $USER_HOME/.local/bin。"
    return 0
}

show_summary() {
    echo -e "\n${COLOR_GREEN}========================================================"
    echo -e "      🎉 Python 开发环境配置完成! 🎉"
    echo -e "--------------------------------------------------------${COLOR_RESET}"
    echo -e "已为您安装好 ${COLOR_YELLOW}pyenv, poetry, pdm, uv${COLOR_RESET}。"
    echo -e "为确保所有更改完全生效, 请执行以下操作:"
    echo -e "\n  1. ${COLOR_YELLOW}关闭当前所有的终端窗口。${COLOR_RESET}"
    echo -e "  2. ${COLOR_YELLOW}重新打开一个新的终端。${COLOR_RESET}"
    echo -e "\n然后您就可以开始使用新工具了:"
    echo -e "  - 使用 ${COLOR_GREEN}pyenv install <version>${COLOR_RESET} 来安装任意 Python 版本 (例如: 3.10)。"
    echo -e "  - 在您的项目目录中, 使用 ${COLOR_GREEN}pyenv local <version>${COLOR_RESET} 来设置项目级的 Python 版本。"
    echo -e "  - ${COLOR_GREEN}poetry${COLOR_RESET}, ${COLOR_GREEN}pdm${COLOR_RESET}, 和 ${COLOR_GREEN}uv${COLOR_RESET} 命令现在应该可以直接使用了。"
    echo -e "  - 试试极速的 ${COLOR_GREEN}uv pip install <package>${COLOR_RESET} 体验飞一般的感觉！"
    echo -e "${COLOR_GREEN}========================================================${COLOR_RESET}\n"
}

# --- 主逻辑 ---
main() {
    log_info "欢迎使用 Python 全功能开发环境配置向导！"
    log_info "本脚本将为您安装 pyenv, poetry, pdm 和 uv。"

    # 1. 身份检查
    check_privileges

    # 2. 网络配置，以便后续所有下载操作都能使用
    network_setup

    # 3. 安装编译依赖
    install_build_dependencies

    # 4. 安装 pyenv 并配置 Shell 环境
    if ! install_pyenv; then
        log_error "Pyenv 安装和配置失败，脚本已中止。"
        exit 1
    fi

    # 5. 安装 poetry
    if ! install_poetry; then
        log_error "Poetry 安装失败，脚本已中止。"
        exit 1
    fi

    # 6. 安装 pdm
    if ! install_pdm; then
        log_error "PDM 安装失败，脚本已中止。"
        exit 1
    fi

    # 7. 安装 uv
    if ! install_uv; then
        log_error "uv 安装失败，脚本已中止。"
        exit 1
    fi

    # 8. 显示总结信息
    show_summary
}

main "$@"
