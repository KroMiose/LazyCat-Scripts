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

# 5. 获取私钥
echo " STEP 5: 请输入私钥文件的【绝对路径】，或直接按 Enter 键后粘贴私钥内容。"
read -p "私钥文件路径: " identity_file_path

identity_file_to_use=""

# 处理拖放文件时可能产生的引号
identity_file_path_clean=$(echo "$identity_file_path" | sed "s/'//g")

if [ -n "$identity_file_path_clean" ]; then
    # 情况一: 用户提供了文件路径
    if [ ! -f "$identity_file_path_clean" ]; then
        echo "❌ 错误: 私钥文件 '${identity_file_path_clean}' 未找到或不是一个有效文件。" >&2
        exit 1
    fi
    identity_file_to_use="$identity_file_path_clean"
    echo "✅ 已确认私钥文件: $identity_file_to_use"
else
    # 情况二: 用户直接回车，准备粘贴密钥
    
    # 根据主机别名定义一个安全的密钥保存路径
    new_key_path="$SSH_DIR/id_rsa_${host_alias}"

    # 检查目标密钥文件是否已存在，防止误覆盖
    if [ -f "$new_key_path" ]; then
        echo ""
        read -p "⚠️  警告: 目标私钥文件 '${new_key_path}' 已存在。您想覆盖它吗? (y/N): " overwrite_key
        if [[ ! "$overwrite_key" =~ ^[Yy]$ ]]; then
            echo "操作已取消，未覆盖任何文件。"
            exit 0
        fi
        echo "好的，现有的密钥文件将被覆盖..."
    fi
    
    echo ""
    echo "请直接粘贴您的私钥内容。输入完成后，在新的一行按 Ctrl+D 结束。"
    
    # 读取多行输入直到遇到 EOF (Ctrl+D)
    echo "⏳ 正在等待您粘贴私钥..."
    cat > "$new_key_path"

    # 检查用户是否真的输入了内容
    if [ ! -s "$new_key_path" ]; then
        echo "❌ 错误: 您没有输入任何内容，或输入为空。" >&2
        rm "$new_key_path" # 清理创建的空文件
        exit 1
    fi

    # 确保文件权限正确
    chmod 600 "$new_key_path"
    identity_file_to_use="$new_key_path"
    echo "✅ 私钥已自动为您保存到: $identity_file_to_use"
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
    IdentityFile ${identity_file_to_use}
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