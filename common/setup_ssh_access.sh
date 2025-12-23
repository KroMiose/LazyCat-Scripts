#!/bin/bash

# ==============================================================================
# 脚本名称: setup_ssh_access.sh
# 功    能: 为当前用户配置免密登录。它会创建一个专用的 SSH 密钥对，
#           将公钥添加到 authorized_keys 中，然后显示私钥，
#           以便您可以从其他计算机使用此私钥登录。
# 适用系统: 所有 Linux & macOS 系统
# 使用方法: bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/linux/setup_ssh_access.sh)"
# ==============================================================================

set -e # 如果任何命令失败，则立即退出

# --- 定义变量 ---
# 使用主机名创建专用密钥的文件名，避免硬编码
KEY_FILENAME="access_key_$(hostname -s)"
KEY_PATH="$HOME/.ssh/${KEY_FILENAME}"
PUBLIC_KEY_PATH="${KEY_PATH}.pub"
AUTHORIZED_KEYS_PATH="$HOME/.ssh/authorized_keys"
KEY_COMMENT="access-key-for-${USER}@$(hostname)"

# --- 准备 .ssh 目录 ---
# 确保 .ssh 目录存在且权限正确
if [ ! -d "$HOME/.ssh" ]; then
    echo "🔑 .ssh 目录不存在，正在创建..."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
fi

# --- 核心理念：幂等性 ---
# 检查专用密钥是否已经生成
if [ -f "$KEY_PATH" ]; then
    echo "✅ 专用的 SSH 登录密钥已经存在。"
else
    echo "⏳ 正在生成专用的 4096 位 RSA SSH 密钥..."
    # 生成一个新的密钥对，用于远程访问
    ssh-keygen -t rsa -b 4096 -f "$KEY_PATH" -N "" -C "$KEY_COMMENT" >/dev/null
    chmod 600 "$KEY_PATH"
    chmod 644 "$PUBLIC_KEY_PATH"
    echo "✅ 新的专用密钥已生成: ${KEY_PATH}"
fi

# 确保公钥已被添加到 authorized_keys
# 使用 grep -q -F 来检查公钥字符串是否已存在于文件中
if [ -f "$AUTHORIZED_KEYS_PATH" ] && grep -q -F "$(cat "$PUBLIC_KEY_PATH")" "$AUTHORIZED_KEYS_PATH"; then
    echo "✅ 公钥已经配置在 authorized_keys 文件中。"
else
    echo "🔧 正在将公钥添加到 authorized_keys..."
    # 追加公钥到 authorized_keys 文件，并确保文件权限正确
    touch "$AUTHORIZED_KEYS_PATH"
    chmod 600 "$AUTHORIZED_KEYS_PATH"
    echo "" >>"$AUTHORIZED_KEYS_PATH" # 添加换行符以防万一
    cat "$PUBLIC_KEY_PATH" >>"$AUTHORIZED_KEYS_PATH"
    # 清理可能产生的重复空行
    awk '!seen[$0]++' "$AUTHORIZED_KEYS_PATH" >"${AUTHORIZED_KEYS_PATH}.tmp" && mv "${AUTHORIZED_KEYS_PATH}.tmp" "$AUTHORIZED_KEYS_PATH"
    echo "✅ 公钥配置完成。"
fi

# --- 输出私钥和使用说明 ---
IP_ADDRESS=$(hostname -I | awk '{print $1}')

echo ""
echo "========================================================================"
echo "      🎉 SSH 访问配置完成! 🎉"
echo "------------------------------------------------------------------------"
echo "  您现在可以使用以下私钥从任何计算机远程登录到此服务器。"
echo "  服务器用户: $USER"
echo "  服务器 IP 地址: $IP_ADDRESS"
echo ""
echo "  👇 这是您需要使用的私钥内容:"
echo "========================================================================"
cat "$KEY_PATH"
echo "" # 在密钥输出后再加一个换行符，让结尾的提示更清晰
echo "========================================================================"
echo "  使用方法:"
echo "  1. 将上面的私钥内容完整复制，并保存到一个文件中 (例如: my_server_key)。"
echo "  2. 在您的本地计算机上，使用以下命令登录:"
echo "     chmod 600 my_server_key"
echo "     ssh -i my_server_key ${USER}@${IP_ADDRESS}"
echo "========================================================================"

exit 0
