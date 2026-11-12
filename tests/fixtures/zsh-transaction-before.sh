#!/bin/bash

# ==============================================================================
# 脚本名称: setup_zsh_p10k.sh
# 功    能: 自动化安装 Zsh, Oh My Zsh, 并可选安装 Powerlevel10k 主题
#           以及 zsh-autosuggestions 和 zsh-syntax-highlighting 插件。
#           它会自动处理 git, curl, zsh 的依赖安装。
# 适用系统: 主流 Linux (Debian/Ubuntu, RHEL/CentOS, Arch) & macOS
# 使用方法: bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/common/setup_zsh_p10k.sh)"
# ==============================================================================

set -euo pipefail

MODE="install"
ASSUME_YES=0
CLEAN_REMOVE_INSTALLED_COMPONENTS=0
CLEAN_REMOVE_LEGACY_LINES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cleanup)
            MODE="cleanup"
            shift
            ;;
        --cleanup-all)
            MODE="cleanup"
            CLEAN_REMOVE_INSTALLED_COMPONENTS=1
            shift
            ;;
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        *)
            echo "❌ 未知参数: $1" >&2
            echo "用法:" >&2
            echo "  - 安装:   $0" >&2
            echo "  - 清理:   $0 --cleanup" >&2
            echo "  - 清理+卸载: $0 --cleanup-all" >&2
            echo "  - 非交互: $0 -y" >&2
            exit 1
            ;;
    esac
done

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

        if [[ "$ASSUME_YES" -eq 1 ]]; then confirm_install=Y; else
        read -p "脚本可以尝试使用 '${pkg_manager}' 为您安装。此操作可能需要 sudo 权限。是否继续？ (Y/n): " confirm_install
        confirm_install=${confirm_install:-Y}
        fi

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

remove_lazycat_managed_block() {
    local zshrc_file="$1"
    local start_marker="# --- LAZYCAT-SCRIPTS ZSH MANAGED START ---"
    local end_marker="# --- LAZYCAT-SCRIPTS ZSH MANAGED END ---"

    [[ ! -L "$zshrc_file" ]] || { echo '拒绝替换符号链接' >&2; return 1; }
    awk -v start="$start_marker" -v end="$end_marker" '
        $0 == start { if (inside || seen++) exit 1; inside=1 }
        $0 == end { if (!inside) exit 1; inside=0 }
        END { if (inside) exit 1 }
    ' "$zshrc_file" || { echo '托管标记损坏，原文件未修改' >&2; return 1; }
    if ! grep -qFx -- "$start_marker" "$zshrc_file"; then return 0; fi

    local tmp_file
    tmp_file="$(mktemp "${zshrc_file}.tmp.XXXXXX")"
    cp -p "$zshrc_file" "$tmp_file"
    awk -v start="$start_marker" -v end="$end_marker" '
        $0 == start { in_block=1; next }
        $0 == end { in_block=0; next }
        !in_block { print }
    ' "$zshrc_file" > "$tmp_file"
    mv "$tmp_file" "$zshrc_file"
}

sanitize_zshrc_known_bad_lines() {
    local zshrc_file="$1"
    local tmp_file
    tmp_file="$(mktemp "${zshrc_file}.tmp.XXXXXX")"
    cp -p "$zshrc_file" "$tmp_file"

    # 历史版本脚本错误地把 `p10k configure` 写进 .zshrc，导致 zsh 启动时直接报错并中断主题/插件加载。
    awk '
        $0 == "# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh." { next }
        $0 == "[[ ! -f ~/.p10k.zsh ]] && p10k configure" { next }
        # 历史版本脚本误用单引号 echo '\nZSH_THEME=...'，导致字面量 \n 写入文件。
        $0 ~ /^\\nZSH_THEME=/ { sub(/^\\n/, "", $0); }
        { print }
    ' "$zshrc_file" > "$tmp_file"
    mv "$tmp_file" "$zshrc_file"
}

zshrc_has_omz_source() {
    local zshrc_file="$1"
    # 匹配常见写法：
    # - source $ZSH/oh-my-zsh.sh
    # - . $ZSH/oh-my-zsh.sh
    # - source ~/.oh-my-zsh/oh-my-zsh.sh
    grep -qE '^[[:space:]]*(source|\.)[[:space:]]+"?(\$ZSH|~\/\.oh-my-zsh|\$HOME\/\.oh-my-zsh)"?\/oh-my-zsh\.sh"?([[:space:]]|$)' "$zshrc_file"
}

inject_lazycat_block_before_omz_source() {
    local zshrc_file="$1"
    local block_file="$2"
    local tmp_file
    tmp_file="$(mktemp "${zshrc_file}.tmp.XXXXXX")"
    cp -p "$zshrc_file" "$tmp_file"

    awk -v block_path="$block_file" '
        BEGIN {
            while ((getline line < block_path) > 0) {
                block = block line "\n"
            }
            close(block_path)
        }
        !inserted && $0 ~ /^[[:space:]]*(source|\.)[[:space:]]+"?(\$ZSH|~\/\.oh-my-zsh|\$HOME\/\.oh-my-zsh)"?\/oh-my-zsh\.sh"?([[:space:]]|$)/ {
            printf "%s", block
            inserted=1
        }
        { print }
    ' "$zshrc_file" > "$tmp_file"
    mv "$tmp_file" "$zshrc_file"
}

append_lazycat_block() {
    local zshrc_file="$1"
    local block_file="$2"
    {
        if [[ -s "$zshrc_file" && -n "$(tail -n 1 "$zshrc_file")" ]]; then echo ""; fi
        cat "$block_file"
    } >> "$zshrc_file"
}

remove_legacy_theme_and_plugin_lines() {
    local zshrc_file="$1"
    local tmp_file
    tmp_file="$(mktemp "${zshrc_file}.tmp.XXXXXX")"
    cp -p "$zshrc_file" "$tmp_file"

    awk '
        # 仅清理历史版本脚本常见注入行（非托管块）。避免误删用户自定义内容。
        $0 == "ZSH_THEME=\"powerlevel10k/powerlevel10k\"" { next }
        $0 ~ /^plugins=\(/ && $0 ~ /zsh-autosuggestions/ && $0 ~ /zsh-syntax-highlighting/ { next }
        { print }
    ' "$zshrc_file" > "$tmp_file"
    mv "$tmp_file" "$zshrc_file"
}


# Work only on a same-directory candidate. Unknown user edits win over commits.
begin_zshrc_edit() {
    ZSHRC_TARGET="$HOME/.zshrc"
    [[ ! -L "$ZSHRC_TARGET" ]] || { echo '.zshrc 是符号链接，需要先明确采纳目标' >&2; exit 1; }
    ZSHRC_LOCK="$HOME/.lazycat-zsh.lock"
    mkdir "$ZSHRC_LOCK" || { echo '另一个操作正在执行，或上次中断留下锁；请先检查' >&2; exit 1; }
    EDIT_DIR=$(mktemp -d "$HOME/.lazycat-zsh.XXXXXX")
    trap 'rm -rf "$EDIT_DIR"; rmdir "$ZSHRC_LOCK"' EXIT
    ZSHRC_EXISTED=0
    if [[ -e "$ZSHRC_TARGET" ]]; then
        ZSHRC_EXISTED=1
        cp -p "$ZSHRC_TARGET" "$EDIT_DIR/before"
    else
        (umask 077; : > "$EDIT_DIR/before")
    fi
    cp -p "$EDIT_DIR/before" "$EDIT_DIR/candidate"
    ZSHRC_FILE="$EDIT_DIR/candidate"
}
commit_zshrc_edit() {
    zsh -n "$ZSHRC_FILE"
    if [[ "$ZSHRC_EXISTED" -eq 1 ]]; then
        [[ ! -L "$ZSHRC_TARGET" ]] && cmp -s "$ZSHRC_TARGET" "$EDIT_DIR/before" || { echo '配置被并发修改，已停止' >&2; exit 1; }
    else
        [[ ! -e "$ZSHRC_TARGET" && ! -L "$ZSHRC_TARGET" ]] || { echo '配置被并发创建，已停止' >&2; exit 1; }
    fi
    if cmp -s "$ZSHRC_FILE" "$EDIT_DIR/before"; then return; fi
    if [[ "$ZSHRC_EXISTED" -eq 1 ]]; then
        local backup
        backup=$(mktemp "$HOME/.zshrc.lazycat.bak.XXXXXX")
        cp -p "$EDIT_DIR/before" "$backup"
    fi
    mv "$ZSHRC_FILE" "$ZSHRC_TARGET"
}

# --- 安全检查 ---
if [ "$(id -u)" -eq 0 ]; then
    echo "❌ 错误: 请不要使用 'sudo' 来运行此脚本。" >&2
    echo "   本脚本旨在配置当前用户的环境，只会在需要时请求 sudo 权限。" >&2
    exit 1
fi

# --- 依赖处理 ---
if [[ "$MODE" == "install" ]]; then
    if [[ -e "$HOME/.oh-my-zsh" || -L "$HOME/.oh-my-zsh" ]]; then
        [[ -d "$HOME/.oh-my-zsh" && -s "$HOME/.oh-my-zsh/oh-my-zsh.sh" && -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]] || {
            echo 'Oh My Zsh 目录存在但加载文件缺失或为空；请先修复，不覆盖现有组件或修改 Shell 配置。' >&2
            exit 1
        }
    fi
    ensure_dependencies
fi

if [[ "$MODE" == "cleanup" ]]; then
    ZSHRC_FILE="$HOME/.zshrc"
    echo "🧹 正在清理 Zsh 配置 (由 LazyCat-Scripts 写入的内容)..."

    [[ -e "$ZSHRC_FILE" ]] || exit 0
    begin_zshrc_edit
    remove_lazycat_managed_block "$ZSHRC_FILE"
    commit_zshrc_edit
    if [[ "$CLEAN_REMOVE_INSTALLED_COMPONENTS" -eq 1 ]]; then
        echo '组件目录没有可验证的安装归属记录，已保留；--cleanup-all 仅移除托管配置。'
    fi

    echo "✅ 清理完成。你现在可以重新运行本脚本进行安装。"
    exit 0
fi

# --- 交互式选项 ---
echo ""
echo "--- Zsh 环境配置选项 ---"
if [[ "$ASSUME_YES" -eq 1 ]]; then
    confirm_p10k="Y"
else
    read -p "是否要安装 Powerlevel10k 主题？ (Y/n): " confirm_p10k
fi
confirm_p10k=${confirm_p10k:-Y} # 默认为 Yes

if [[ "$ASSUME_YES" -eq 1 ]]; then
    confirm_plugins="Y"
else
    read -p "是否要安装 zsh-autosuggestions (自动补全) 和 zsh-syntax-highlighting (语法高亮) 插件？ (Y/n): " confirm_plugins
fi
confirm_plugins=${confirm_plugins:-Y} # 默认为 Yes
echo ""


# --- 安装 Oh My Zsh ---
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "⏳ 正在安装 Oh My Zsh..."
    # 使用 sh -c 来非交互式地运行安装脚本
    # RUNZSH=no: 安装后不立即启动 zsh
    # CHSH=no: 不自动修改默认 shell (因为我们已要求用户手动设置)
    omz_installer=$(mktemp)
    if ! curl -fSL --connect-timeout 15 --max-time 120 https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "$omz_installer"; then
        rm -f "$omz_installer"; exit 1
    fi
    RUNZSH=no CHSH=no sh "$omz_installer" --unattended --keep-zshrc
    rm -f "$omz_installer"
else
    echo "✅ Oh My Zsh 已经安装。"
fi
[[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" && -s "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]] || {
    echo 'Oh My Zsh 安装器未生成有效加载文件；安装未完成，未写入 Shell 配置。' >&2
    exit 1
}

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

begin_zshrc_edit
remove_lazycat_managed_block "$ZSHRC_FILE"

echo "  -> 正在写入托管配置块 (幂等)..."
PLUGINS_LIST=("git")
if [[ "$confirm_plugins" =~ ^[Yy]$ ]]; then
    PLUGINS_LIST+=("zsh-autosuggestions" "zsh-syntax-highlighting")
fi

# --- 关键修复：确保 Oh My Zsh 会被加载，并在其之前注入正确的 p10k 配置加载逻辑 ---
LAZYCAT_BLOCK_FILE="$(mktemp)"
{
    echo "# --- LAZYCAT-SCRIPTS ZSH MANAGED START ---"
    echo "# 由 LazyCat-Scripts 管理：确保 OMZ / P10k 加载顺序正确且可重复执行。"
    echo 'export ZSH="$HOME/.oh-my-zsh"'
    echo 'typeset -ga plugins'
    echo 'typeset -gU plugins'
    echo "plugins+=( ${PLUGINS_LIST[*]} )"
    if [[ "$confirm_p10k" =~ ^[Yy]$ ]]; then
        echo 'ZSH_THEME="powerlevel10k/powerlevel10k"'
        echo '[[ ! -f "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"'
        echo '# 如需生成/重跑向导：请在 Zsh 里手动执行 p10k configure'
    fi
    echo "# --- LAZYCAT-SCRIPTS ZSH MANAGED END ---"
} > "$LAZYCAT_BLOCK_FILE"

if zshrc_has_omz_source "$ZSHRC_FILE"; then
    # 已存在 source 行：把托管块插入到 source 之前，确保变量和 p10k 配置生效
    inject_lazycat_block_before_omz_source "$ZSHRC_FILE" "$LAZYCAT_BLOCK_FILE"
else
    # 不存在 source 行：追加一个包含 source 的托管块，保证 OMZ/主题/插件能实际加载
    LAZYCAT_BLOCK_WITH_SOURCE_FILE="$(mktemp)"
    {
        sed '$d' "$LAZYCAT_BLOCK_FILE"
        echo 'source "$ZSH/oh-my-zsh.sh"'
        echo '# --- LAZYCAT-SCRIPTS ZSH MANAGED END ---'
    } > "$LAZYCAT_BLOCK_WITH_SOURCE_FILE"
    append_lazycat_block "$ZSHRC_FILE" "$LAZYCAT_BLOCK_WITH_SOURCE_FILE"
    rm -f "$LAZYCAT_BLOCK_WITH_SOURCE_FILE"
fi
rm -f "$LAZYCAT_BLOCK_FILE"

commit_zshrc_edit
echo "✅ .zshrc 配置完成。"

echo '默认 Shell 保持不变；需要切换时请单独运行 chsh。'

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
