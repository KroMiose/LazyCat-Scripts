#!/bin/bash

# ==============================================================================
# 脚本名称: setup_sudo_nopasswd.sh
# 功    能: 为当前 sudo 用户配置或移除免密 sudo 权限。
# 警    告: 这是一个高风险操作，会显著降低系统安全性。请仅在受信任的环境中使用。
# 适用系统: 使用 sudo 和 /etc/sudoers.d/ 的 Linux 发行版。
# 使用方法: sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/linux/setup_sudo_nopasswd.sh)"
# ==============================================================================

set -e
set -o pipefail

# --- 安全检查: 必须以 root/sudo 身份运行 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 错误: 此脚本需要使用 'sudo' 来运行。" >&2
    exit 1
fi

# --- 获取调用此脚本的真实用户信息 ---
# 当使用 'sudo' 时, SUDO_USER 变量会保存原始用户的名称
CALLING_USER="$SUDO_USER"
if [ -z "$CALLING_USER" ] || [ "$CALLING_USER" = "root" ]; then
    echo "❌ 错误: 无法确定调用此脚本的普通用户身份。" >&2
    echo "   请确保您是以普通用户身份通过 'sudo' 来执行此脚本。" >&2
    exit 1
fi

# --- 定义配置文件路径 ---
# 文件名使用 99- 前缀确保它在其他规则之后被加载，并且包含用户名以示清晰。
SUDOERS_FILE="/etc/sudoers.d/99-nopasswd-${CALLING_USER}"

# --- 启用免密 sudo 的函数 ---
enable_nopasswd() {
    echo "即将为用户 '$CALLING_USER' 创建免密 sudo 规则..."
    echo "🚨 警告: 这是一个高风险操作，请再次确认。"
    # 要求用户输入 "yes" 来确认，避免意外操作
    read -p "如果您完全理解风险并希望继续，请输入 'yes': " confirm
    if [ "$confirm" != "yes" ]; then
        echo "🛑 操作已取消。"
        exit 0
    fi

    echo "  -> 正在创建 sudoers 配置文件: $SUDOERS_FILE"

    # 定义要写入的配置内容
    CONFIG_CONTENT="$CALLING_USER ALL=(ALL) NOPASSWD: ALL"

    # 使用 tee 和 sudo 来写入文件，这是在脚本中安全写入特权文件的标准做法
    echo "$CONFIG_CONTENT" | sudo tee "$SUDOERS_FILE" >/dev/null

    echo "  -> 设置文件权限为 0440 (只读，属主和属组可读)..."
    sudo chmod 0440 "$SUDOERS_FILE"

    echo "  -> 正在使用 'visudo -c' 验证 sudoers 文件语法..."
    if sudo visudo -c -f "$SUDOERS_FILE"; then
        echo "✅ 语法验证通过，配置完成。"
    else
        echo "❌ 严重错误: sudoers 文件语法无效！" >&2
        echo "   为了系统安全，将自动移除刚刚创建的无效配置文件。" >&2
        sudo rm -f "$SUDOERS_FILE"
        exit 1
    fi

    echo ""
    echo "🎉 成功！用户 '$CALLING_USER' 现在可以免密使用 sudo。"
    echo "   此更改立即生效。"
}

# --- 移除免密 sudo 的函数 ---
disable_nopasswd() {
    if [ ! -f "$SUDOERS_FILE" ]; then
        echo "ℹ️  未找到为用户 '$CALLING_USER' 配置的免密文件 ($SUDOERS_FILE)。"
        echo "   无需执行任何操作。"
        exit 0
    fi

    echo "即将移除用户 '$CALLING_USER' 的免密 sudo 规则..."
    read -p "您确定要恢复密码验证吗？ (Y/n): " confirm
    confirm=${confirm:-Y}
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "🛑 操作已取消。"
        exit 0
    fi

    echo "  -> 正在移除 sudoers 配置文件: $SUDOERS_FILE"
    sudo rm -f "$SUDOERS_FILE"

    echo ""
    echo "✅ 成功！用户 '$CALLING_USER' 的免密 sudo 配置已被移除。"
    echo "   从现在开始，执行 sudo 将需要输入密码。"
}

# --- 主逻辑：交互式菜单 ---
main_menu() {
    echo "--------------------------------------------------------"
    echo "    Sudo 免密配置向导 for user: $CALLING_USER"
    echo "--------------------------------------------------------"
    echo "🚨 警告: 允许 sudo 免密执行是高风险操作。"
    echo "   它会降低您系统的安全性，请仅在完全受信任的"
    echo "   私有环境或临时虚拟机中使用此功能。"
    echo "--------------------------------------------------------"
    echo
    echo "请选择您要执行的操作:"
    echo "  1) 启用 (或更新) '$CALLING_USER' 用户的免密 sudo"
    echo "  2) 移除 '$CALLING_USER' 用户的免密 sudo 配置"
    echo "  q) 退出"
    echo

    read -p "请输入选项 [1-2, q]: " choice
    echo

    case "$choice" in
    1)
        enable_nopasswd
        ;;
    2)
        disable_nopasswd
        ;;
    q | Q)
        echo "👋 操作已取消，未做任何更改。"
        exit 0
        ;;
    *)
        echo "❌ 无效选项，请输入 1, 2, 或 q。"
        exit 1
        ;;
    esac
}

# --- 脚本入口 ---
main_menu
exit 0
