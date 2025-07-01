#!/bin/bash

# ==============================================================================
# 脚本名称: add_ssh_config.sh
# 功    能: 交互式地将一个新的 SSH 服务器配置添加到 ~/.ssh/config 文件中，
#           方便用户通过别名快速登录。
# 适用系统: 所有 Linux & macOS 系统
# 使用方法: bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/scripts/main/linux/add_ssh_config.sh)"
# ==============================================================================

set -e

# --- 准备 .ssh 目录和 config 文件 ---
SSH_DIR="$HOME/.ssh"
SSH_CONFIG_PATH="$SSH_DIR/config"

if [ ! -d "$SSH_DIR" ]; then
    echo "🔧 首次使用，正在创建 .ssh 目录..."
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
fi
if [ ! -f "$SSH_CONFIG_PATH" ]; then
    echo "🔧 首次使用，正在创建 .ssh/config 文件..."
    touch "$SSH_CONFIG_PATH"
    chmod 600 "$SSH_CONFIG_PATH"
fi

# --- 交互式获取信息 ---
echo ""
echo "---  SSH 配置小助手 ---"
echo "我将引导您添加一个新的 SSH 服务器配置。"
echo ""

# 1. 获取服务器别名
read -p " STEP 1: 请输入一个好记的服务器别名 (例如: prod-server): " host_alias
if [ -z "$host_alias" ]; then
    echo "❌ 错误: 服务器别名不能为空。" >&2
    exit 1
fi

# 2. 获取 IP 或域名
read -p " STEP 2: 请输入服务器的 IP 地址或域名: " hostname
if [ -z "$hostname" ]; then
    echo "❌ 错误: IP 地址或域名不能为空。" >&2
    exit 1
fi

# 3. 获取用户名
read -p " STEP 3: 请输入登录服务器的用户名: " user
if [ -z "$user" ]; then
    echo "❌ 错误: 用户名不能为空。" >&2
    exit 1
fi

# 4. 获取端口号
read -p " STEP 4: 请输入服务器的 SSH 端口 (默认为 22): " port
port=${port:-22} # 如果用户未输入，则使用默认值 22

# 5. 获取私钥路径
read -p " STEP 5: 请输入私钥文件的【绝对路径】(或拖动文件到此): " identity_file
# 处理拖放文件时可能产生的引号
identity_file_clean=$(echo "$identity_file" | sed "s/'//g")
if [ ! -f "$identity_file_clean" ]; then
    echo "❌ 错误: 私钥文件 '${identity_file_clean}' 未找到或不是一个有效文件。" >&2
    exit 1
fi

# --- 准备配置内容 ---
# IdentitiesOnly=yes 是一个好习惯，它强制 SSH 只使用此文件中指定的密钥
CONFIG_BLOCK="
Host ${host_alias}
    HostName ${hostname}
    User ${user}"

if [[ "$port" != "22" ]]; then
    CONFIG_BLOCK+="
    Port ${port}"
fi

CONFIG_BLOCK+="
    IdentityFile ${identity_file_clean}
    IdentitiesOnly yes
"

# --- 幂等性检查与写入操作 ---
# 检查主机别名是否已存在
if grep -q -E "^\s*Host\s+${host_alias}\s*$" "$SSH_CONFIG_PATH"; then
    echo ""
    read -p "⚠️  警告: 配置 '${host_alias}' 已存在。您想覆盖它吗? (y/N): " overwrite
    if [[ "$overwrite" =~ ^[Yy]$ ]]; then
        echo "⏳ 正在备份并覆盖现有配置..."
        # 创建一个备份
        cp "$SSH_CONFIG_PATH" "${SSH_CONFIG_PATH}.bak.$(date +%s)"
        
        # 使用 awk 过滤掉旧的配置块
        awk -v alias="$host_alias" '
            BEGIN { in_block=0 }
            /^\s*Host\s+/ {
                if ($2 == alias) { in_block=1; next }
                else { in_block=0 }
            }
            !in_block { print }
        ' "$SSH_CONFIG_PATH" > "${SSH_CONFIG_PATH}.tmp"
        
        # 将新块追加到临时文件
        echo "$CONFIG_BLOCK" >> "${SSH_CONFIG_PATH}.tmp"
        
        # 替换原文件
        mv "${SSH_CONFIG_PATH}.tmp" "$SSH_CONFIG_PATH"
        
        echo "✅ 配置 '${host_alias}' 已成功更新。"
    else
        echo "操作已取消。"
        exit 0
    fi
else
    # 如果不存在，直接追加
    echo "⏳ 正在添加新配置..."
    echo "$CONFIG_BLOCK" >> "$SSH_CONFIG_PATH"
    echo "✅ 新配置 '${host_alias}' 已成功添加。"
fi

# --- 完成后提示 ---
echo ""
echo "========================================================"
echo "      🎉 全部搞定! 🎉"
echo "--------------------------------------------------------"
echo "  您现在可以直接使用以下命令登录服务器了:"
echo ""
echo "      ssh ${host_alias}"
echo ""
echo "========================================================"

exit 0 