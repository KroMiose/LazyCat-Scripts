#!/bin/bash

# ==============================================================================
# 脚本名称: setup_zsh_p10k.sh
# 功    能: 自动化安装 Zsh, Oh My Zsh, 并可选安装 Powerlevel10k 主题
#           以及 zsh-autosuggestions 和 zsh-syntax-highlighting 插件。
#           它会自动处理 git, curl, zsh 的依赖安装。
# 适用系统: 主流 Linux (Debian/Ubuntu, RHEL/CentOS, Arch) & macOS
# 使用方法: bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/scripts/main/linux/setup_zsh_p10k.sh)"
# ==============================================================================

set -e

# Function to check for and install missing dependencies
ensure_dependencies() {
    local required_cmds=("git" "curl" "zsh")
    local missing_cmds=()
    local cmd
    echo "🔎 正在检查所需依赖..."
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        echo "⚠️  检测到以下依赖项缺失: ${missing_cmds[*]}"
        
        local pkg_manager=""
        local install_cmd=""

        if [[ "$(uname)" == "Darwin" ]]; then
            if ! command -v brew >/dev/null 2>&1; then
                echo "❌ 错误: Homebrew 未安装。请先从 https://brew.sh/ 安装。" >&2
                exit 1
            fi
            pkg_manager="Homebrew"
            install_cmd="brew install ${missing_cmds[*]}"
        elif command -v apt-get >/dev/null 2>&1; then
            pkg_manager="apt"
            install_cmd="sudo apt-get update && sudo apt-get install -y ${missing_cmds[*]}"
        elif command -v dnf >/dev/null 2>&1; then
            pkg_manager="dnf"
            install_cmd="sudo dnf install -y ${missing_cmds[*]}"
        elif command -v yum >/dev/null 2>&1; then
            pkg_manager="yum"
            install_cmd="sudo yum install -y ${missing_cmds[*]}"
        elif command -v pacman >/dev/null 2>&1; then
            pkg_manager="pacman"
            install_cmd="sudo pacman -S --noconfirm --needed ${missing_cmds[*]}"
        else
            echo "❌ 无法检测到支持的包管理器 (apt, dnf, yum, pacman, brew)。" >&2
            echo "   请您手动安装缺失的依赖后，再重新运行此脚本。" >&2
            exit 1
        fi

        read -p "脚本可以尝试使用 '${pkg_manager}' 为您安装。此操作可能需要 sudo 权限。是否继续？ (Y/n): " confirm_install
        confirm_install=${confirm_install:-Y}

        if [[ "$confirm_install" =~ ^[Yy]$ ]]; then
            echo "⏳ 正在运行安装命令..."
            eval "$install_cmd"
            
            for cmd in "${missing_cmds[@]}"; do
                if ! command -v "$cmd" >/dev/null 2>&1; then
                    echo "❌ 错误: '$cmd' 安装失败。请您手动安装后再试。" >&2
                    exit 1
                fi
            done
            echo "✅ 所有依赖均已成功安装。"
        else
            echo "🛑 用户取消了安装。请您手动安装依赖。"
            exit 1
        fi
    else
        echo "✅ 所有依赖项均已安装。"
    fi
}


# --- 安全检查 ---
if [ "$(id -u)" -eq 0 ]; then
    echo "❌ 错误: 请不要使用 'sudo' 来运行此脚本。" >&2
    echo "   本脚本旨在配置当前用户的环境，只会在需要时请求 sudo 权限。" >&2
    exit 1
fi

# --- 依赖处理 ---
ensure_dependencies

# --- 交互式选项 ---
echo ""
echo "--- Zsh 环境配置选项 ---"
read -p "是否要安装 Powerlevel10k 主题？ (Y/n): " confirm_p10k
confirm_p10k=${confirm_p10k:-Y} # 默认为 Yes

read -p "是否要安装 zsh-autosuggestions (自动补全) 和 zsh-syntax-highlighting (语法高亮) 插件？ (Y/n): " confirm_plugins
confirm_plugins=${confirm_plugins:-Y} # 默认为 Yes
echo ""


# --- 安装 Oh My Zsh ---
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "⏳ 正在安装 Oh My Zsh..."
    # 使用 sh -c 来非交互式地运行安装脚本
    # RUNZSH=no: 安装后不立即启动 zsh
    # CHSH=no: 不自动修改默认 shell (因为我们已要求用户手动设置)
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc
else
    echo "✅ Oh My Zsh 已经安装。"
fi

# 定义 Zsh 插件和主题的自定义目录
ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"

# --- 根据选择安装组件 ---
if [[ "$confirm_p10k" =~ ^[Yy]$ ]]; then
    if [ ! -d "${ZSH_CUSTOM}/themes/powerlevel10k" ]; then
        echo "⏳ 正在安装 Powerlevel10k 主题..."
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${ZSH_CUSTOM}/themes/powerlevel10k"
    else
        echo "✅ Powerlevel10k 主题已经安装。"
    fi
fi

if [[ "$confirm_plugins" =~ ^[Yy]$ ]]; then
    if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-autosuggestions" ]; then
        echo "⏳ 正在安装 zsh-autosuggestions 插件 (自动补全)..."
        git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "${ZSH_CUSTOM}/plugins/zsh-autosuggestions"
    else
        echo "✅ zsh-autosuggestions 插件已经安装。"
    fi

    if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting" ]; then
        echo "⏳ 正在安装 zsh-syntax-highlighting 插件 (语法高亮)..."
        git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"
    else
        echo "✅ zsh-syntax-highlighting 插件已经安装。"
    fi
fi

# --- 配置 .zshrc ---
ZSHRC_FILE="$HOME/.zshrc"
echo "🔧 正在配置 .zshrc 文件..."

# 创建一个 .zshrc 的备份，更加安全
cp "$ZSHRC_FILE" "${ZSHRC_FILE}.bak.$(date +'%Y-%m-%d_%H-%M-%S')"
echo "  -> 已创建备份文件: ${ZSHRC_FILE}.bak.*"

# 根据选择配置 P10k 主题
if [[ "$confirm_p10k" =~ ^[Yy]$ ]]; then
    echo "  -> 正在配置 Powerlevel10k 主题..."
    # 使用 grep 和 sed 安全地替换或追加主题设置
    if grep -qE '^\s*ZSH_THEME=' "$ZSHRC_FILE"; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' 's/^\s*ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$ZSHRC_FILE"
        else
            sed -i 's/^\s*ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$ZSHRC_FILE"
        fi
    else
        echo '\nZSH_THEME="powerlevel10k/powerlevel10k"' >> "$ZSHRC_FILE"
    fi

    # 添加 P10k 首次运行配置
    P10K_CONFIG_LINE='[[ ! -f ~/.p10k.zsh ]] && p10k configure'
    if ! grep -qF -- "$P10K_CONFIG_LINE" "$ZSHRC_FILE"; then
        echo -e "\n# To customize prompt, run \`p10k configure\` or edit ~/.p10k.zsh.\n${P10K_CONFIG_LINE}" >> "$ZSHRC_FILE"
    fi
fi

# 根据选择配置插件
if [[ "$confirm_plugins" =~ ^[Yy]$ ]]; then
    echo "  -> 正在配置插件..."
    # 检查 'plugins=(...)' 行是否存在
    if grep -qE '^\s*plugins=\(' "$ZSHRC_FILE"; then
        # 检查是否为默认的 'plugins=(git)'
        if grep -qE '^\s*plugins=\(git\)\s*$' "$ZSHRC_FILE"; then
            echo "  -> 找到默认插件配置，正在添加新插件..."
            sed_command="s/^\s*plugins=\(git\)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/"
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' "$sed_command" "$ZSHRC_FILE"
            else
                sed -i "$sed_command" "$ZSHRC_FILE"
            fi
        else
            echo "  -> ⚠️  检测到您有自定义的插件列表！为了安全，脚本不会自动修改它。"
            echo "     请您手动将 'zsh-autosuggestions' 和 'zsh-syntax-highlighting' 添加到"
            echo "     .zshrc 文件中的 'plugins=(...)' 列表里。"
        fi
    else
        # 如果连 'plugins=(...)' 行都找不到，就添加一个
        echo "  -> 未找到 plugins=(...) 设置，正在添加..."
        echo '\nplugins=(git zsh-autosuggestions zsh-syntax-highlighting)' >> "$ZSHRC_FILE"
    fi
fi

echo "✅ .zshrc 配置完成。"

# --- Set Zsh as default shell ---
# Check if zsh was just installed or if the current shell is not zsh
if [[ " ${missing_cmds[*]} " =~ " zsh " ]] || [[ "$SHELL" != */zsh ]]; then
    read -p "是否要将 Zsh 设置为您的默认 Shell？ (Y/n): " confirm_chsh
    confirm_chsh=${confirm_chsh:-Y}
    if [[ "$confirm_chsh" =~ ^[Yy]$ ]]; then
        echo "⏳ 正在尝试将默认 Shell 更改为 Zsh。此过程可能需要您的密码。"
        if chsh -s "$(command -v zsh)"; then
            echo "✅ 默认 Shell 已成功更改。"
        else
            echo "⚠️  自动更改默认 Shell 失败。您可以手动运行此命令尝试: chsh -s $(command -v zsh)"
        fi
    fi
fi

# --- 完成后提示 ---
echo ""
echo "========================================================================"
echo "      🎉 Zsh 环境配置完成! 🎉"
echo "------------------------------------------------------------------------"
echo "  所有您请求的组件均已安装和配置完毕。请执行最后一步:"
echo ""

if [[ "$confirm_p10k" =~ ^[Yy]$ ]]; then
    echo "  1. 字体安装 (重要!):"
    echo "     为了完美显示 Powerlevel10k 的图标，您需要在您的终端里"
    echo "     安装并启用一个 Nerd Font 字体。推荐使用 'MesloLGS NF'。"
    echo "     您可以从这里下载: https://github.com/romkatv/powerlevel10k#meslo-nerd-font-patched-for-powerlevel10k"
    echo ""
fi

echo "  - 启动 Zsh:"
echo "     请注销并重新登录，以使所有更改（包括默认 Shell）完全生效。"
echo "     或者，在当前窗口输入 'exec zsh' 来立即体验新配置。"
echo ""

if [[ "$confirm_p10k" =~ ^[Yy]$ ]]; then
    echo "  - Powerlevel10k 配置:"
    echo "     当您第一次启动 Zsh 时，Powerlevel10k 的配置向导会自动运行。"
    echo "     请根据提示回答问题，打造您专属的酷炫终端！"
fi
echo "========================================================================"

exit 0 