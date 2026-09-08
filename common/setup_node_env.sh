#!/bin/bash

# ==============================================================================
# 脚本名称: setup_node_env.sh
# 功    能: 在 Linux/macOS 系统上提供一个交互式向导，用于安装 nvm (Node Version Manager)
#           并可选安装指定的 Node.js 版本 (如 LTS) 和流行的包管理器 (yarn, pnpm)。
# 目标平台: Linux / macOS；具体自动验证范围与限制见 docs/TESTING.md。
# 仓库入口: bash common/setup_node_env.sh；安装与兼容说明见 common/README.md。
# ==============================================================================

set -e -o pipefail

if [[ "$EUID" == 0 ]]; then
    echo '此脚本不应以 root 或 sudo 身份运行，请以普通用户执行。' >&2
    exit 1
fi

if [[ "${1:-}" == --check ]]; then
    export NVM_DIR="$HOME/.nvm"
    [[ -s "$NVM_DIR/nvm.sh" ]] || { echo "nvm 安装不完整" >&2; exit 1; }
    source "$NVM_DIR/nvm.sh"
    node --version
    node -e 'if (2 + 2 !== 4) process.exit(1)'
    npm --version
    exit
fi

SET_DEFAULT=0
if [[ "${1:-}" == --set-default ]]; then SET_DEFAULT=1; shift; fi
[[ $# == 0 ]] || { echo '用法：[--check | --set-default]' >&2; exit 2; }

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
USER_HOME="$HOME"

# --- 功能函数 ---

# 函数：检查核心依赖
check_dependencies() {
    log_info "正在检查核心依赖: curl, git..."
    local missing_deps=()
    if ! command -v curl &>/dev/null; then
        missing_deps+=("curl")
    fi
    if ! command -v git &>/dev/null; then
        missing_deps+=("git")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "缺少必要的依赖: ${missing_deps[*]}。"
        log_info "请先安装它们。以下是常见系统的安装命令示例:"
        log_info "  - Debian/Ubuntu: sudo apt update && sudo apt install ${missing_deps[*]}"
        log_info "  - RHEL/CentOS:   sudo yum install ${missing_deps[*]}"
        log_info "  - Fedora:        sudo dnf install ${missing_deps[*]}"
        log_info "  - Arch Linux:    sudo pacman -S ${missing_deps[*]}"
        log_info "  - macOS (Homebrew): brew install ${missing_deps[*]}"
        exit 1
    fi
    log_success "所有核心依赖都已满足。"
}

# 函数：安装 nvm 并交互式安装 Node.js
install_nvm_and_node() {
    # 步骤 2: 安装 nvm
    if [[ -d "$USER_HOME/.nvm" && ! -s "$USER_HOME/.nvm/nvm.sh" ]]; then
        log_error "nvm 目录存在但安装不完整，保留现状，请明确修复。"; return 1
    fi
    if [ -s "$USER_HOME/.nvm/nvm.sh" ]; then
        log_info "nvm 已经安装在 $USER_HOME/.nvm，跳过安装。"
    else
        log_info "正在从 GitHub 下载并安装 nvm..."
        local nvm_version=v0.40.3 installer
        installer=$(mktemp)
        if ! curl -fLsS --connect-timeout 10 --max-time 120 "https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_version}/install.sh" -o "$installer"; then
            rm -f "$installer"
            return 1
        fi
        if ! bash "$installer"; then rm -f "$installer"; return 1; fi
        rm -f "$installer"

        log_success "nvm 安装脚本执行完毕，继续验证实际命令。"
    fi

    # 加载 nvm 到当前 shell session
    export NVM_DIR="$USER_HOME/.nvm"
    [[ -s "$NVM_DIR/nvm.sh" ]] || { log_error "安装器未生成有效 nvm.sh。"; return 1; }
    source "$NVM_DIR/nvm.sh"
    nvm --version || { log_error "nvm 健康检查失败。"; return 1; }
    if [[ -s "$NVM_DIR/bash_completion" ]]; then source "$NVM_DIR/bash_completion"; fi

    # 步骤 3: 交互式安装 Node.js
    log_info "请选择要安装的 Node.js 版本:"
    PS3="请输入选项 (1-3): "
    local selected=0
    select choice in "安装最新的 LTS (长期支持) 版本" "安装指定的版本号" "退出"; do
        case $choice in
        "安装最新的 LTS (长期支持) 版本")
            log_info "正在安装最新的 Node.js LTS 版本..."
            if nvm install --lts; then
                verify_node_runtime || return 1
                log_success "Node.js LTS 版本安装成功！"
                log_info "正在设置默认 Node.js 版本为最新的 LTS..."
                if [[ ! -s "$NVM_DIR/alias/default" || "$SET_DEFAULT" == 1 ]]; then nvm alias default 'lts/*'; fi
                log_success "默认版本已检查，已有默认版本保持不变（除非显式 --set-default）。"
            else
                log_error "Node.js LTS 版本安装失败。"
                return 1
            fi
            selected=1
            break
            ;;
        "安装指定的版本号")
            read -p "请输入您想安装的 Node.js 版本号 (例如: 18.18.2): " node_version
            if [ -n "$node_version" ]; then
                log_info "正在安装 Node.js v${node_version}..."
                if nvm install "$node_version"; then
                    verify_node_runtime || return 1
                    log_success "Node.js v${node_version} 安装成功！"
                    log_info "正在设置默认 Node.js 版本为 v${node_version}..."
                    if [[ ! -s "$NVM_DIR/alias/default" || "$SET_DEFAULT" == 1 ]]; then nvm alias default "$node_version"; fi
                    log_success "默认版本已检查，已有默认版本保持不变（除非显式 --set-default）。"
                else
                    log_error "Node.js v${node_version} 安装失败。"
                    return 1
                fi
            else
                log_warn "未输入版本号，操作取消。"
            fi
            selected=1
            break
            ;;
        "退出")
            log_info "用户选择退出 Node.js 安装。"
            exit 0
            ;;
        *)
            log_warn "无效的选项，请重新输入。"
            ;;
        esac
    done
    [[ "$selected" == 1 ]] || { log_error "未收到有效安装选择，未完成配置。"; return 1; }
}

verify_node_runtime() {
    node --version && node -e 'if (2 + 2 !== 4) process.exit(1)' && npm --version || {
        log_error "Node/npm 实际运行验证失败，未确认安装成功。"
        return 1
    }
}

# 函数：交互式安装 npm 全局工具
install_npm_tools() {
    # 再次加载 nvm 环境，确保 npm 可用
    export NVM_DIR="$USER_HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

    if ! command -v npm &>/dev/null; then
        log_warn "未找到 npm 命令，跳过全局工具安装。"
        log_warn "这可能是因为您在上一步没有选择安装任何 Node.js 版本。"
        return
    fi

    log_info "接下来，您可以选择安装一些流行的全局 npm 工具。"
    local tools_to_install=("yarn" "pnpm")
    for tool in "${tools_to_install[@]}"; do
        read -p "$(echo -e "${COLOR_YELLOW}QUESTION: 是否要安装 ${tool}？(y/N): ${COLOR_RESET}")" choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            log_info "正在使用 'npm' 全局安装 '${tool}'..."
            if npm install -g "${tool}"; then
                log_success "'${tool}' 安装成功！"
            else
                log_error "'${tool}' 安装失败。"
                return 1
            fi
        else
            log_info "跳过安装 '${tool}'。"
        fi
    done
}

# 函数：显示最后的总结信息
show_summary() {
    echo -e "\n${COLOR_GREEN}========================================================"
    echo -e "      🎉 Node.js 环境配置完成! 🎉"
    echo -e "--------------------------------------------------------${COLOR_RESET}"
    echo -e "为确保所有更改完全生效, 请执行以下操作:"
    echo -e "\n  1. ${COLOR_YELLOW}关闭当前所有的终端窗口。${COLOR_RESET}"
    echo -e "  2. ${COLOR_YELLOW}重新打开一个新的终端。${COLOR_RESET}"
    echo -e "\n然后您就可以在新的终端中使用以下命令:"
    echo -e "  - ${COLOR_BLUE}nvm --version${COLOR_RESET} (查看 nvm 版本)"
    echo -e "  - ${COLOR_BLUE}nvm ls${COLOR_RESET} (查看已安装的 Node.js 版本)"
    echo -e "  - ${COLOR_BLUE}node --version${COLOR_RESET} (查看当前的默认 Node.js 版本)"
    echo -e "  - ${COLOR_BLUE}npm --version${COLOR_RESET} (查看 npm 版本)"
    echo -e "${COLOR_GREEN}========================================================${COLOR_RESET}\n"
}

# --- 主逻辑 ---
main() {
    log_info "欢迎使用 Node.js 环境配置向导！"

    # 步骤 1: 检查依赖
    check_dependencies

    # 步骤 2 & 3: 安装 nvm 和 Node.js
    install_nvm_and_node

    # 步骤 4: 交互式选择并安装其他工具 (yarn, pnpm)
    install_npm_tools

    # 步骤 5: 显示最终摘要
    show_summary
}

# --- 脚本执行入口 ---
main "$@"
