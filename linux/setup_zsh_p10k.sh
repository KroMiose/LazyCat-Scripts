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
    echo "🔎 Checking for required dependencies..."
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        echo "⚠️ The following dependencies are missing: ${missing_cmds[*]}"
        
        local pkg_manager=""
        local install_cmd=""

        if [[ "$(uname)" == "Darwin" ]]; then
            if ! command -v brew >/dev/null 2>&1; then
                echo "❌ Homebrew is not installed. Please install it first from https://brew.sh/" >&2
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
            echo "❌ Could not detect a supported package manager (apt, dnf, yum, pacman, brew)." >&2
            echo "   Please install the missing dependencies manually and run the script again." >&2
            exit 1
        fi

        read -p "This script can attempt to install them using '${pkg_manager}'. This may require sudo privileges. Proceed? (Y/n): " confirm_install
        confirm_install=${confirm_install:-Y}

        if [[ "$confirm_install" =~ ^[Yy]$ ]]; then
            echo "⏳ Running installation command..."
            eval "$install_cmd"
            
            for cmd in "${missing_cmds[@]}"; do
                if ! command -v "$cmd" >/dev/null 2>&1; then
                    echo "❌ Failed to install '$cmd'. Please install it manually and try again." >&2
                    exit 1
                fi
            done
            echo "✅ All dependencies are now installed."
        else
            echo "🛑 Installation aborted by user. Please install dependencies manually."
            exit 1
        fi
    else
        echo "✅ All dependencies are already installed."
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

read -p "是否要安装 zsh-autosuggestions 和 zsh-syntax-highlighting 插件？ (Y/n): " confirm_plugins
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
cp "$ZSHRC_FILE" "${ZSHRC_FILE}.bak.$(date +%s)"
echo "  -> 已创建备份文件: ${ZSHRC_FILE}.bak.*"

if [[ "$confirm_p10k" =~ ^[Yy]$ ]]; then
    echo "  -> 正在配置 Powerlevel10k 主题..."
    if grep -qE '^\s*ZSH_THEME=' "$ZSHRC_FILE"; then
        sed -i '' 's/^\s*ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$ZSHRC_FILE"
    else
        echo "  -> 未找到 ZSH_THEME 设置，正在添加..."
        echo '\nZSH_THEME="powerlevel10k/powerlevel10k"' >> "$ZSHRC_FILE"
    fi

    P10K_CONFIG_LINE='[[ ! -f ~/.p10k.zsh ]] && p10k configure'
    if ! grep -qF -- "$P10K_CONFIG_LINE" "$ZSHRC_FILE"; then
        echo "  -> 正在添加 Powerlevel10k 首次运行配置..."
        echo -e "\n# To customize prompt, run \`p10k configure\` or edit ~/.p10k.zsh.\n${P10K_CONFIG_LINE}" >> "$ZSHRC_FILE"
    fi
fi

if [[ "$confirm_plugins" =~ ^[Yy]$ ]]; then
    echo "  -> 正在配置插件..."
    if grep -qE '^\s*plugins=\(' "$ZSHRC_FILE"; then
        # 检查是否为默认的 'plugins=(git)'
        if grep -qE '^\s*plugins=\(git\)\s*$' "$ZSHRC_FILE"; then
            echo "  -> 找到默认的插件配置，正在添加新插件..."
            sed -i '' 's/^\s*plugins=\(git\)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' "$ZSHRC_FILE"
        else
            # 如果不是默认配置，提示用户手动添加
            echo "  -> ⚠️  检测到您有自定义的插件列表！"
            echo "     为了安全，脚本不会自动修改它。"
            echo "     请您手动将 'zsh-autosuggestions' 和 'zsh-syntax-highlighting' 添加到"
            echo "     .zshrc 文件中的 'plugins=(...)' 列表里。"
        fi
    else
        # 如果连 plugins=(...) 这行都找不到，就添加一个
        echo "  -> 未找到 plugins=(...) 设置，正在添加..."
        echo '\nplugins=(git zsh-autosuggestions zsh-syntax-highlighting)' >> "$ZSHRC_FILE"
    fi
fi

# 修复 sed 在 macOS 上创建的额外备份文件
rm -f "${ZSHRC_FILE}.bak"

echo "✅ .zshrc 配置完成。"

# --- Set Zsh as default shell ---
# Check if zsh was just installed or if the current shell is not zsh
if [[ " ${missing_cmds[*]} " =~ " zsh " ]] || [[ "$SHELL" != */zsh ]]; then
    read -p "Do you want to set Zsh as your default shell? (Y/n): " confirm_chsh
    confirm_chsh=${confirm_chsh:-Y}
    if [[ "$confirm_chsh" =~ ^[Yy]$ ]]; then
        echo "⏳ Trying to change the default shell to Zsh. This may ask for your password."
        if chsh -s "$(command -v zsh)"; then
            echo "✅ Default shell changed successfully."
        else
            echo "⚠️ Failed to change default shell automatically. You can try to do it manually by running: chsh -s $(command -v zsh)"
        fi
    fi
fi

# --- 完成后提示 ---
echo ""
echo "========================================================================"
echo "      🎉 Zsh 环境配置完成! 🎉"
echo "------------------------------------------------------------------------"
echo "  所有请求的组件已安装和配置。请执行以下最后一步:"
echo ""

if [[ "$confirm_p10k" =~ ^[Yy]$ ]]; then
    echo "  1. 字体安装 (重要!):"
    echo "     为了完美显示 Powerlevel10k 的图标，您需要在您的终端里"
    echo "     安装并启用一个 Nerd Font 字体。推荐使用 'MesloLGS NF'。"
    echo "     您可以从这里下载: https://github.com/romkatv/powerlevel10k#meslo-nerd-font-patched-for-powerlevel10k"
    echo ""
fi

echo "  - 启动 Zsh:"
echo "     注销并重新登录以使所有更改（包括默认shell）完全生效。"
echo "     或者，在当前窗口输入 'exec zsh' 来立即体验新配置。"
echo ""

if [[ "$confirm_p10k" =~ ^[Yy]$ ]]; then
    echo "  - Powerlevel10k 配置:"
    echo "     当您第一次启动 Zsh 时，Powerlevel10k 的配置向导会自动运行。"
    echo "     请根据提示回答问题，打造您专属的酷炫终端！"
fi
echo "========================================================================"

exit 0 