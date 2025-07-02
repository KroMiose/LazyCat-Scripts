#!/bin/bash

# ==============================================================================
# 脚本名称: setup_python_env.sh
# 功    能: 在 Debian/Ubuntu 系统上，通过系统包管理器 (apt) 提供一个交互式向导，
#           用于安装和配置一个现代化的 Python 开发环境。
#           支持从官方源或 PPA (deadsnakes) 安装指定版本的 Python,
#           并可选安装 pipx, poetry, pdm 等流行工具。
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

# --- 核心辅助函数 ---

# 在模拟的用户真实登录环境中执行命令
# 用于需要以普通用户身份执行的操作，例如 'pipx'
run_as_user() {
    local script_to_run="$1"
    sudo -i -u "$REAL_USER" bash <<<"set -e; ${script_to_run}"
}

# --- 系统与依赖检查 ---

check_system() {
    if ! [ -f /etc/debian_version ]; then
        log_error "此脚本目前仅为基于 Debian/Ubuntu 的系统优化。"
        log_error "在您的系统上运行可能会导致未知问题。"
        read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 您确定要继续吗？ (y/N): ${COLOR_RESET}")" choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log_info "脚本终止。"
            exit 0
        fi
    fi
}

install_dependencies() {
    log_info "正在更新软件包列表并安装基础依赖..."
    apt-get update
    # software-properties-common 用于 add-apt-repository
    # python3-pip 和 python3-venv 是 Python 环境的基础
    # pipx 用于管理 python 工具, 通过 apt 安装以避免 'externally-managed-environment' 错误
    apt-get install -y software-properties-common python3-pip python3-venv pipx
    log_success "基础依赖安装完毕。"
}

# --- Python 安装与配置 ---

select_and_install_python_apt() {
    read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 是否添加 deadsnakes PPA 以获取更多/更新的 Python 版本？(推荐)(Y/n): ${COLOR_RESET}")" choice
    if [[ ! "$choice" =~ ^[Nn]$ ]]; then
        log_info "正在添加 deadsnakes PPA..."
        if add-apt-repository -y ppa:deadsnakes/ppa; then
            log_success "deadsnakes PPA 添加成功。"
        else
            log_error "添加 deadsnakes PPA 失败。将仅从官方源查找。"
        fi
        log_info "正在更新软件包列表..."
        apt-get update
    fi

    log_info "正在查找可用的 Python 版本..."
    # 查找所有名为 python3.xx 的软件包
    local available_pythons
    mapfile -t available_pythons < <(apt-cache pkgnames | grep -E '^python3\.[0-9]{1,2}$' | sort -rV)

    if [ ${#available_pythons[@]} -eq 0 ]; then
        log_error "未找到可供安装的 'python3.x' 软件包。"
        log_warn "您可以尝试手动运行 'apt-get update' 或检查您的软件源配置。"
        return 1
    fi

    log_info "请选择您希望安装的 Python 版本:"
    select python_pkg in "${available_pythons[@]}" "退出安装"; do
        case "$python_pkg" in
        "退出安装")
            log_info "用户选择退出安装。"
            return 0
            ;;
        "")
            log_warn "无效选项，请重新选择。"
            ;;
        *)
            log_info "您选择了 ${python_pkg}."
            break
            ;;
        esac
    done

    log_info "正在安装 ${python_pkg} 及其 venv 模块..."
    if ! apt-get install -y "$python_pkg" "${python_pkg}-venv"; then
        log_error "${python_pkg} 安装失败。请检查 apt 的输出信息。"
        return 1
    fi
    log_success "${python_pkg} 安装成功！"

    configure_python_alternatives
}

configure_python_alternatives() {
    log_info "正在配置系统默认的 'python3' 命令..."

    # 查找 /usr/bin 下所有已安装的 python3.x 可执行文件
    local installed_pythons
    mapfile -t installed_pythons < <(find /usr/bin/python3.* -maxdepth 0 -type f -executable 2>/dev/null | grep -E 'python3\.[0-9]+$' | sort -rV)

    if [ ${#installed_pythons[@]} -eq 0 ]; then
        log_error "在 /usr/bin 中未找到任何 'python3.x' 可执行文件。"
        return 1
    fi

    # 确保所有找到的 Python 都被注册到 update-alternatives 系统中
    log_info "将已安装的 Python 版本注册到系统选择中..."
    for p_path in "${installed_pythons[@]}"; do
        # 检查该路径是否已作为 python3 的一个候选项存在
        if ! update-alternatives --display python3 | grep -q -x "$p_path"; then
            local version_name
            version_name=$(basename "$p_path")
            log_info "  -> 正在添加 ${version_name}..."
            # 使用版本号的数字作为优先级，使得新版本有更高优先级
            # 例如: python3.11 -> 311
            local priority
            priority=$(echo "$version_name" | sed 's/python//' | tr -d '.')
            update-alternatives --install /usr/bin/python3 python3 "$p_path" "$priority"
        fi
    done

    # 通过交互式菜单让用户选择默认版本
    log_info "您现在可以通过交互式菜单选择默认的 'python3' 版本。"
    log_warn "请在接下来的菜单中输入您想要的版本的编号，然后按 Enter。"
    update-alternatives --config python3

    # 验证最终选择
    local current_python_path
    current_python_path=$(update-alternatives --query python3 | grep 'Value:' | awk '{print $2}')
    if [ -n "$current_python_path" ]; then
        log_success "默认 'python3' 已设置为: $current_python_path"
        log_info "当前版本: $(${current_python_path} --version)"
    else
        log_error "无法确认默认 Python 版本。"
    fi
}

# 函数：安装 pipx 并通过它安装其他工具
install_pipx_and_tools() {
    if ! command -v python3 &>/dev/null; then
        log_warn "未找到 'python3' 命令。将跳过 pipx 和相关工具的安装。"
        return 1
    fi

    # pipx 已通过 apt 在 install_dependencies 中安装
    log_info "正在为您的 Shell 配置 pipx 路径..."
    if run_as_user "pipx ensurepath"; then
        log_success "'pipx' 路径配置成功。"
    else
        log_error "'pipx' 路径配置失败。"
    fi
    log_info "请注意: 'pipx' 的路径将在下次登录时生效。"

    local tools_to_install=("poetry" "pdm")
    for tool in "${tools_to_install[@]}"; do
        read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 是否要安装 ${tool}？(y/N): ${COLOR_RESET}")" choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            log_info "正在使用 'pipx' 安装 '${tool}'..."
            # 使用 run_as_user 来确保在用户的环境中执行
            if run_as_user "pipx install ${tool}"; then
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
    echo -e "  - ${COLOR_BLUE}python3 --version${COLOR_RESET} (查看当前的默认 Python 版本)"
    echo -e "  - ${COLOR_BLUE}update-alternatives --config python3${COLOR_RESET} (随时切换默认版本)"
    echo -e "  - ${COLOR_BLUE}pipx list${COLOR_RESET} (查看已安装的 Python 工具)"
    echo -e "${COLOR_GREEN}========================================================${COLOR_RESET}\n"
}

# --- 主逻辑 ---
main() {
    log_info "欢迎使用 Python 环境配置向导！"
    log_info "将为用户 '$REAL_USER' 在系统范围内配置环境。"

    # 步骤 0: 检查系统并安装依赖
    check_system
    install_dependencies

    # 步骤 1: 交互式选择并安装 Python 版本
    select_and_install_python_apt

    # 步骤 2: 安装 pipx 和其他工具
    install_pipx_and_tools

    # 步骤 3: 显示最终摘要
    show_summary
}

# --- 脚本执行入口 ---
main "$@"
