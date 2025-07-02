#!/bin/bash

# ==============================================================================
# 脚本名称: setup_python_env.sh
# 功    能: 在 Linux 系统上提供一个交互式向导，用于安装和配置一个干净、
#           现代化的 Python 开发环境。支持通过 pyenv 安装指定版本的 Python，
#           并可选安装 pipx, poetry, pdm 等流行工具。
# 适用系统: 基于 Debian/Ubuntu, RHEL/CentOS/Fedora, Arch Linux 的系统。
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
# 必须以 root 或 sudo 权限运行
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 'sudo' 来运行此脚本。"
    exit 1
fi

# 获取真正调用脚本的用户名和家目录
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
else
    log_error "无法确定普通用户身份。请使用 'sudo' 运行。"
    exit 1
fi

if [ ! -d "$USER_HOME" ]; then
    log_error "无法找到用户 '$REAL_USER' 的家目录: $USER_HOME"
    exit 1
fi

# --- pyenv 和 Python 工具安装 ---

# 函数：为 pyenv 安装系统级依赖
# 来源: https://github.com/pyenv/pyenv/wiki/Common-build-problems
install_pyenv_dependencies() {
    log_info "正在检测系统并安装 'pyenv' 的编译依赖..."
    if [ -f /etc/debian_version ]; then
        # Debian/Ubuntu
        apt-get update
        apt-get install -y make build-essential libssl-dev zlib1g-dev \
            libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
            libncurses5-dev libncursesw5-dev xz-utils tk-dev libffi-dev \
            liblzma-dev python3-openssl git
    elif [ -f /etc/redhat-release ]; then
        # RHEL/CentOS/Fedora
        yum install -y gcc zlib-devel bzip2 bzip2-devel readline-devel \
            sqlite sqlite-devel openssl-devel xz xz-devel libffi-devel findutils
    elif [ -f /etc/arch-release ]; then
        # Arch Linux
        pacman -Syu --noconfirm base-devel openssl zlib xz tk
    else
        log_warn "无法检测到您的 Linux 发行版，将跳过依赖安装。"
        log_warn "如果 Python 安装失败，请根据 pyenv-installer 的指引手动安装依赖。"
    fi
    log_success "pyenv 依赖项处理完毕。"
}

# 函数：安装 pyenv 并配置 shell
install_pyenv() {
    if [ -d "$USER_HOME/.pyenv" ]; then
        log_info "'pyenv' 已经安装在 $USER_HOME/.pyenv，跳过安装。"
        return
    fi

    log_info "正在为用户 '$REAL_USER' 安装 'pyenv'..."
    log_info "正在尝试从官方 GitHub 源克隆 'pyenv'..."
    if ! git clone https://github.com/pyenv/pyenv.git "$USER_HOME/.pyenv"; then
        log_warn "从官方源克隆 'pyenv' 失败，这可能是网络问题。"
        local choice
        read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 是否尝试使用代理 (ghproxy.com) 重新克隆？(y/N): ${COLOR_RESET}")" choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            log_info "正在尝试通过代理 (ghproxy.com) 克隆 'pyenv'..."
            if ! git clone https://ghproxy.com/https://github.com/pyenv/pyenv.git "$USER_HOME/.pyenv"; then
                log_error "通过代理克隆 'pyenv' 仓库同样失败。"
                log_error "请检查您的网络连接或尝试其他代理。"
                exit 1
            fi
        else
            log_error "用户选择不使用代理，脚本终止。"
            exit 1
        fi
    fi

    # 确保 .pyenv 目录的所有权正确
    chown -R "$REAL_USER":"$REAL_USER" "$USER_HOME/.pyenv"

    # 确保用户主目录的基本权限正确
    chown "$REAL_USER":"$REAL_USER" "$USER_HOME"

    # 为所有相关的 shell 配置文件添加 pyenv 初始化代码
    log_info "正在为 shell 配置文件（.profile, .bashrc, .zprofile, .zshrc）添加 pyenv 初始化代码..."

    local shell_configs=("$USER_HOME/.profile" "$USER_HOME/.bashrc" "$USER_HOME/.zprofile" "$USER_HOME/.zshrc")
    local pyenv_config='\n# pyenv configuration\nexport PYENV_ROOT="$HOME/.pyenv"\nexport PATH="$PYENV_ROOT/bin:$PATH"\nif command -v pyenv 1>/dev/null 2>&1; then\n  eval "$(pyenv init --path)"\n  eval "$(pyenv init -)"\nfi\n'

    for config_file in "${shell_configs[@]}"; do
        # 即使文件不存在，也要确保为其添加配置
        if ! grep -q 'PYENV_ROOT' "$config_file" 2>/dev/null; then
            log_info "  -> 正在向 $config_file 添加配置..."
            echo -e "$pyenv_config" >>"$config_file"
            chown "$REAL_USER":"$REAL_USER" "$config_file"
        else
            log_warn "  -> $config_file 中已存在 pyenv 配置，跳过。"
        fi
    done
    log_success "'pyenv' 安装并配置完毕！"
}

# 函数：交互式地选择并安装 Python 版本
select_and_install_python() {
    # 使用 pyenv 真实可执行文件的绝对路径，而不是符号链接
    local PYENV_CMD="$USER_HOME/.pyenv/libexec/pyenv"

    # 检查并配置代理和镜像源
    local proxy_env=""
    local mirror_env=""

    # 检查是否已有代理配置
    if [[ -z "$http_proxy" && -z "$https_proxy" ]]; then
        read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 检测到未配置代理。是否需要配置代理以加速 Python 下载？(y/N): ${COLOR_RESET}")" use_proxy
        if [[ "$use_proxy" =~ ^[Yy]$ ]]; then
            read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 请输入代理地址 (例如: http://127.0.0.1:7890): ${COLOR_RESET}")" proxy_url
            if [[ -n "$proxy_url" ]]; then
                proxy_env="http_proxy=$proxy_url https_proxy=$proxy_url"
                log_info "将使用代理: $proxy_url"
            fi
        fi
    else
        log_info "检测到已有代理配置，将自动使用。"
        proxy_env="http_proxy=$http_proxy https_proxy=$https_proxy"
    fi

    # 询问是否使用国内镜像源
    read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 是否使用国内镜像源加速 Python 下载？(推荐)(Y/n): ${COLOR_RESET}")" use_mirror
    if [[ ! "$use_mirror" =~ ^[Nn]$ ]]; then
        # 先尝试几个不同的镜像源
        echo "1) pyenv-mirror.vercel.app (推荐)"
        echo "2) pyenv.ibeats.top"
        echo "3) 清华大学镜像源"
        read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 请选择镜像源 (1-3, 默认: 1): ${COLOR_RESET}")" mirror_choice
        case "${mirror_choice:-1}" in
        1)
            mirror_env="PYTHON_BUILD_MIRROR_URL=https://pyenv-mirror.vercel.app/api/pythons/"
            log_info "将使用 pyenv-mirror.vercel.app 镜像源。"
            ;;
        2)
            mirror_env="PYTHON_BUILD_MIRROR_URL=https://pyenv.ibeats.top"
            log_info "将使用 pyenv.ibeats.top 镜像源。"
            ;;
        3)
            mirror_env="PYTHON_BUILD_MIRROR_URL_SKIP_CHECKSUM=1 PYTHON_BUILD_MIRROR_URL=https://mirrors.tuna.tsinghua.edu.cn/python/"
            log_info "将使用清华大学镜像源。"
            ;;
        *)
            mirror_env="PYTHON_BUILD_MIRROR_URL=https://pyenv-mirror.vercel.app/api/pythons/"
            log_info "使用默认镜像源: pyenv-mirror.vercel.app"
            ;;
        esac
    fi

    local major_version
    read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 请输入您想安装的 Python 主版本号 (例如: 3.12, 3.11): ${COLOR_RESET}")" major_version

    if ! [[ "$major_version" =~ ^3\.[0-9]{1,2}$ ]]; then
        log_error "无效的格式。请输入类似 '3.12' 的版本号。"
        return 1
    fi

    log_info "正在查找 ${major_version} 的最新可用稳定版本..."
    local latest_version
    # 使用 pyenv 的绝对路径执行命令，并应用代理配置
    latest_version=$(sudo -u "$REAL_USER" env $proxy_env "$PYENV_CMD" install --list | awk '/^ *'${major_version}'\.[0-9]+ *$/ {print $1}' | sort -V | tail -n 1)

    if [ -z "$latest_version" ]; then
        log_error "未找到 ${major_version} 的任何可用稳定版本。请检查版本号或网络连接。"
        return 1
    fi

    local choice
    read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 找到的最新版本是 ${latest_version}。是否安装此版本并设为全局默认？(y/N): ${COLOR_RESET}")" choice
    if ! [[ "$choice" =~ ^[Yy]$ ]]; then
        log_info "用户取消安装。"
        return 0
    fi

    local installed_versions
    installed_versions=$(sudo -u "$REAL_USER" env $proxy_env "$PYENV_CMD" versions --bare)

    if echo "$installed_versions" | grep -q "^${latest_version}$"; then
        log_info "Python 版本 ${latest_version} 已经安装。"
    else
        log_info "正在使用 'pyenv' 安装 Python ${latest_version}... (这可能需要几分钟)"
        log_info "如果下载缓慢，请耐心等待或考虑配置更快的代理。"
        
        log_info "正在以用户登录会话 (sudo -i) 进行 Python 构建以确保环境正确..."
        # The pyenv init commands should have been added to .profile or .zprofile
        # which are read by a login shell.
        local install_script="
            set -e
            export $proxy_env
            export $mirror_env
            $PYENV_CMD install ${latest_version}
        "
        
        # 使用 `sudo -i -u` 来模拟一个真实的用户登录, 这会加载用户的 profile 文件,
        # 确保所有的环境变量和路径都已正确设置。
        if ! sudo -i -u "$REAL_USER" bash <<< "$install_script"; then
            log_error "Python ${latest_version} 安装失败。"
            log_error "这可能是网络问题或持续的权限问题。"
            log_error "您也可以参考 https://github.com/pyenv/pyenv/wiki/Common-build-problems"
            return 1
        fi
        log_success "Python ${latest_version} 安装成功！"
    fi

    log_info "正在将 Python ${latest_version} 设置为全局版本..."
    sudo -i -u "$REAL_USER" "$PYENV_CMD" global ${latest_version}
    log_success "全局 Python 版本已设置为 $(sudo -i -u "$REAL_USER" "$PYENV_CMD" global)。"
}

# 函数：安装 pipx 并通过它安装其他工具
install_pipx_and_tools() {
    # 使用 pyenv 真实可执行文件的绝对路径
    local PYENV_CMD="$USER_HOME/.pyenv/libexec/pyenv"

    # 检查全局 python 版本是否已设置
    if ! sudo -i -u "$REAL_USER" "$PYENV_CMD" which python &>/dev/null; then
        log_error "未找到由 pyenv 管理的 Python。请先选择并安装一个 Python 版本。"
        return 1
    fi

    log_info "正在为用户 '$REAL_USER' 安装 'pipx'..."
    local pipx_install_script="
        set -e
        python -m pip install --user pipx
        python -m pipx ensurepath
    "
    if sudo -i -u "$REAL_USER" bash <<< "$pipx_install_script"; then
        log_success "'pipx' 安装和路径配置成功。"
        log_info "请注意: 'pipx' 的路径将在下次登录时生效。"
    else
        log_error "'pipx' 安装或路径配置失败。"
        return 1
    fi

    local tools_to_install=("poetry" "pdm")
    for tool in "${tools_to_install[@]}"; do
        read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 是否要安装 ${tool}？(y/N): ${COLOR_RESET}")" choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            log_info "正在使用 'pipx' 安装 '${tool}'..."
            local tool_install_script="
                set -e
                python -m pipx install ${tool}
            "
            if sudo -i -u "$REAL_USER" bash <<< "$tool_install_script"; then
                log_success "'${tool}' 安装成功！"
            else
                log_error "'${tool}' 安装失败。"
            fi
        else
            log_info "跳过安装 '${tool}'。"
        fi
    done
}

# 函数：显示最后的总结信息
show_summary() {
    echo -e "\n${COLOR_GREEN}========================================================"
    echo -e "      🎉 Python 环境配置完成! 🎉"
    echo -e "--------------------------------------------------------${COLOR_RESET}"
    echo -e "为确保所有更改完全生效, 请执行以下操作:"
    echo -e "\n  1. ${COLOR_YELLOW}关闭当前所有的终端窗口。${COLOR_RESET}"
    echo -e "  2. ${COLOR_YELLOW}重新打开一个新的终端。${COLOR_RESET}"
    echo -e "\n然后您就可以在新的终端中使用以下命令:"
    echo -e "  - ${COLOR_BLUE}pyenv versions${COLOR_RESET} (查看已安装的 Python 版本)"
    echo -e "  - ${COLOR_BLUE}python --version${COLOR_RESET} (查看当前的全局 Python 版本)"
    echo -e "  - ${COLOR_BLUE}pipx list${COLOR_RESET} (查看已安装的 Python 工具)"
    echo -e "${COLOR_GREEN}========================================================${COLOR_RESET}\n"
}

# --- 主逻辑 ---
main() {
    log_info "欢迎使用 Python 环境配置向导！"
    log_info "将为用户 '$REAL_USER' 在 '$USER_HOME' 中配置环境。"

    # 步骤 1: 安装 pyenv 及其依赖
    install_pyenv_dependencies
    install_pyenv

    # 步骤 2: 交互式选择并安装 Python 版本
    select_and_install_python

    # 步骤 3 & 4: 安装 pipx 和其他工具
    install_pipx_and_tools

    # 步骤 5: 显示最终摘要
    show_summary
}

# --- 脚本执行入口 ---
main "$@"
