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
[[ "$CALLING_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*\$?$ ]] || { echo '用户名不能安全表示为现有 sudoers 文件名，未修改权限。' >&2; exit 2; }
target_uid=$(id -u -- "$CALLING_USER") || { echo '目标用户不存在，未修改权限。' >&2; exit 2; }
[[ "$target_uid" != 0 ]] || { echo '目标必须为普通用户，未修改权限。' >&2; exit 2; }

# --- 定义配置文件路径 ---
# 文件名使用 99- 前缀确保它在其他规则之后被加载，并且包含用户名以示清晰。
SUDOERS_FILE="/etc/sudoers.d/99-nopasswd-${CALLING_USER}"
CONFIG_CONTENT="$CALLING_USER ALL=(ALL) NOPASSWD: ALL"

check_owned_rule() {
    [[ ! -L "$SUDOERS_FILE" ]] || { echo 'sudoers 文件为符号链接，未修改。' >&2; return 3; }
    if [[ -e "$SUDOERS_FILE" ]]; then
        [[ -f "$SUDOERS_FILE" ]] && printf '%s\n' "$CONFIG_CONTENT" | cmp -s - "$SUDOERS_FILE" || {
            echo 'sudoers 文件包含无法确认归属的修改，保留原权限；请先审阅。' >&2
            return 3
        }
    fi
}

# Include inode/ctime so edits made while a confirmation prompt is open are
# conflicts even when the file still has the same text and mode.
rule_revision() {
    [[ ! -L "$SUDOERS_FILE" ]] || return 3
    if [[ -e "$SUDOERS_FILE" ]]; then
        LC_ALL=C stat -c '%d:%i:%z' -- "$SUDOERS_FILE"
    else printf 'absent\n'; fi
}
check_rule_revision() {
    check_owned_rule || return "$?"
    [[ "$(rule_revision)" == "$1" ]] || { echo '确认期间 sudoers 被并发修改，保留当前权限。' >&2; return 3; }
}

# --- 启用免密 sudo 的函数 ---
enable_nopasswd() {
    check_owned_rule || return "$?"
    local observed
    observed=$(rule_revision) || return "$?"
    echo "即将为用户 '$CALLING_USER' 创建免密 sudo 规则..."
    echo "🚨 警告: 这是一个高风险操作，请再次确认。"
    # 要求用户输入 "yes" 来确认，避免意外操作
    read -p "如果您完全理解风险并希望继续，请输入 'yes': " confirm
    if [ "$confirm" != "yes" ]; then
        echo "🛑 操作已取消。"
        exit 0
    fi

    check_rule_revision "$observed" || return "$?"
    echo "  -> 正在创建 sudoers 配置文件: $SUDOERS_FILE"

    # 定义要写入的配置内容
    CONFIG_CONTENT="$CALLING_USER ALL=(ALL) NOPASSWD: ALL"

    [[ ! -L "$SUDOERS_FILE" ]] || { echo '拒绝替换符号链接' >&2; return 1; }
    local candidate backup
    candidate=$(mktemp /etc/sudoers.d/.lazycat-check.XXXXXX)
    backup=$(mktemp /etc/sudoers.d/.lazycat-before.XXXXXX)
    if [[ -f "$SUDOERS_FILE" ]]; then cp -p "$SUDOERS_FILE" "$backup"; else rm -f "$backup"; fi
    printf '%s\n' "$CONFIG_CONTENT" > "$candidate"
    chmod 0440 "$candidate"
    if ! visudo -c -f "$candidate"; then rm -f "$candidate" "$backup"; return 1; fi
    # An unchanged owned line is not evidence that the complete policy is valid.
    if ! visudo -c; then rm -f "$candidate" "$backup"; return 1; fi
    if ! check_rule_revision "$observed"; then rm -f "$candidate" "$backup"; return 3; fi
    if [[ -f "$SUDOERS_FILE" ]] && cmp -s "$candidate" "$SUDOERS_FILE"; then
        rm -f "$candidate" "$backup"
        echo '配置未变化。'
        return 0
    fi
    mv "$candidate" "$SUDOERS_FILE"
    if ! visudo -c; then
        if [[ -f "$backup" ]]; then mv "$backup" "$SUDOERS_FILE"; else rm -f "$SUDOERS_FILE"; fi
        return 1
    fi
    if [[ -f "$backup" ]]; then mv "$backup" "${SUDOERS_FILE}.bak.$(date +%s)"; fi

    echo ""
    echo "🎉 成功！用户 '$CALLING_USER' 现在可以免密使用 sudo。"
    echo "   此更改立即生效。"
}

# --- 移除免密 sudo 的函数 ---
disable_nopasswd() {
    check_owned_rule || return "$?"
    local observed
    observed=$(rule_revision) || return "$?"
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

    check_rule_revision "$observed" || return "$?"
    echo "  -> 正在移除 sudoers 配置文件: $SUDOERS_FILE"
    rm -f "$SUDOERS_FILE"

    echo ""
    echo "✅ 成功！用户 '$CALLING_USER' 的免密 sudo 配置已被移除。"
    echo "   本工具规则已移除；是否仍可免密取决于其他 sudoers 规则。"
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
