#!/bin/bash

# ==============================================================================
# 脚本名称: setup_proxy_config.sh
# 功    能: 交互式地为 Shell 环境配置和取消代理的便捷命令。
#           支持连接测试、临时配置和永久配置。
# 适用系统: 所有主流 Linux 发行版及 macOS (Bash/Zsh)
# 使用方法: bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/linux/setup_proxy_config.sh)"
# ==============================================================================

set -e

# --- 安全检查: 避免以 root 身份运行 ---
if [ "$(id -u)" -eq 0 ]; then
    echo "❌ 错误: 请不要使用 'sudo' 来运行此脚本。" >&2
    echo "   本脚本用于配置当前用户的 Shell 环境。" >&2
    exit 1
fi

# --- 尝试从环境变量中获取现有代理配置 ---
EXISTING_PROXY=""
# 优先使用小写的变量，因为它们更通用
if [ -n "$http_proxy" ]; then
    EXISTING_PROXY="$http_proxy"
elif [ -n "$https_proxy" ]; then
    EXISTING_PROXY="$https_proxy"
elif [ -n "$all_proxy" ]; then
    EXISTING_PROXY="$all_proxy"
# 作为备选，检查大写变量
elif [ -n "$HTTP_PROXY" ]; then
    EXISTING_PROXY="$HTTP_PROXY"
elif [ -n "$HTTPS_PROXY" ]; then
    EXISTING_PROXY="$HTTPS_PROXY"
elif [ -n "$ALL_PROXY" ]; then
    EXISTING_PROXY="$ALL_PROXY"
fi

DEFAULT_HOST="127.0.0.1"
DEFAULT_PORT="7890"

if [ -n "$EXISTING_PROXY" ]; then
    echo "🔍 检测到现有代理环境变量: $EXISTING_PROXY"
    # 移除协议头 (http://, https://, socks5://, etc.) 和尾部斜杠
    PROXY_NO_PROTOCOL=$(echo "$EXISTING_PROXY" | sed -E 's_.*://__; s_/$__')
    # 从 user:pass@host:port 中提取 host:port
    PROXY_HOST_PORT=$(echo "$PROXY_NO_PROTOCOL" | sed -E 's/.*@//')
    # 提取主机和端口
    DEFAULT_HOST=$(echo "$PROXY_HOST_PORT" | awk -F: '{print $1}')
    DEFAULT_PORT=$(echo "$PROXY_HOST_PORT" | awk -F: '{print $2}')
    echo "  -> 将使用 Host: $DEFAULT_HOST, Port: $DEFAULT_PORT 作为默认值。"
fi

# --- 交互式获取代理信息 ---
echo "--- 代理配置向导 ---"
read -p "请输入代理服务器地址 (默认: ${DEFAULT_HOST}): " PROXY_HOST
PROXY_HOST=${PROXY_HOST:-${DEFAULT_HOST}}

read -p "请输入代理服务器端口 (默认: ${DEFAULT_PORT}): " PROXY_PORT
PROXY_PORT=${PROXY_PORT:-${DEFAULT_PORT}}

echo ""
echo "✨ 您的代理配置如下:"
echo "   - 地址: ${PROXY_HOST}"
echo "   - 端口: ${PROXY_PORT}"
echo ""

# --- 测试函数 ---
perform_tests() {
    local host="$1"
    local port="$2"
    local all_ok=true
    local any_ok=false

    echo "--- 正在执行代理连通性测试 (超时时间 5s) ---"
    
    local test_url_http="http://ifconfig.me"
    local test_url_https="https://ifconfig.me"
    
    # Test HTTP
    printf "  - [1/3] 测试 HTTP 代理... "
    http_ip=$(HTTP_PROXY="http://${host}:${port}" curl --connect-timeout 5 -s "$test_url_http")
    if [ $? -eq 0 ] && [ -n "$http_ip" ]; then
        printf "✅ 成功 (出口 IP: %s)\n" "$http_ip"
        any_ok=true
    else
        printf "❌ 失败\n"
        all_ok=false
    fi

    # Test HTTPS
    printf "  - [2/3] 测试 HTTPS 代理... "
    https_output=$(HTTPS_PROXY="http://${host}:${port}" curl --connect-timeout 5 -s -w "\n%{time_total}" "$test_url_https")
    if [ $? -eq 0 ] && [[ "$https_output" == *$'\n'* ]]; then
        https_ip=$(echo -n "$https_output" | head -n 1)
        latency_s=$(echo -n "$https_output" | tail -n 1)
        latency_ms=$(awk -v s="$latency_s" 'BEGIN{printf "%.0f", s * 1000}')
        printf "✅ 成功 (出口 IP: %s, 延迟: %s ms)\n" "$https_ip" "$latency_ms"
        any_ok=true
    else
        printf "❌ 失败\n"
        all_ok=false
    fi

    # Test SOCKS5
    printf "  - [3/3] 测试 SOCKS5 代理... "
    socks_ip=$(curl --connect-timeout 5 -s --socks5-hostname "${host}:${port}" "$test_url_https")
    if [ $? -eq 0 ] && [ -n "$socks_ip" ]; then
        printf "✅ 成功 (出口 IP: %s)\n" "$socks_ip"
        any_ok=true
    else
        printf "❌ 失败\n"
        all_ok=false
    fi
    echo "--- 测试完成 ---"
    echo ""

    if $all_ok; then
        return 0 # All passed
    elif $any_ok; then
        return 1 # Some passed
    else
        return 2 # All failed
    fi
}

# --- 可选的测试环节 ---
read -p "是否在继续前测试此代理配置？ (Y/n): " confirm_test
confirm_test=${confirm_test:-Y}

if [[ "$confirm_test" =~ ^[Yy]$ ]]; then
    perform_tests "$PROXY_HOST" "$PROXY_PORT"
    test_result=$?

    proceed_anyway=false
    if [ $test_result -eq 0 ]; then
        echo "🎉 所有测试均成功通过！"
        proceed_anyway=true
    elif [ $test_result -eq 1 ]; then
        echo "⚠️  部分测试失败。如果您的代理不支持所有协议，这可能是正常的。"
        read -p "是否仍然继续？ (y/N): " confirm_proceed
        if [[ "$confirm_proceed" =~ ^[Yy]$ ]]; then
            proceed_anyway=true
        fi
    else # test_result is 2
        echo "❌ 所有测试均失败。代理地址或端口很可能配置错误。"
        read -p "是否仍然继续 (不推荐)？ (y/N): " confirm_proceed
        if [[ "$confirm_proceed" =~ ^[Yy]$ ]]; then
            proceed_anyway=true
        fi
    fi

    if ! $proceed_anyway; then
        echo "🛑 操作已取消。"
        exit 0
    fi
    echo ""
fi

# --- 询问用户最终操作 ---
read -p "您想如何应用此配置？ [P]ermanent (写入文件) / [T]emporary (仅显示命令) (P/t): " choice
choice=${choice:-P}

if [[ "$choice" =~ ^[Tt]$ ]]; then
    # --- 临时使用 ---
    echo ""
    echo "======================== 临时使用说明 ========================"
    echo "请复制并粘贴以下命令到您的终端以开启代理："
    echo "------------------------------------------------------------"
    echo "export http_proxy=\"http://${PROXY_HOST}:${PROXY_PORT}\""
    echo "export https_proxy=\"http://${PROXY_HOST}:${PROXY_PORT}\""
    echo "export all_proxy=\"socks5://${PROXY_HOST}:${PROXY_PORT}\""
    echo "export no_proxy=\"localhost,127.0.0.1,::1,*.local\""
    echo "------------------------------------------------------------"
    echo ""
    echo "当您不再需要代理时，请运行以下命令关闭它："
    echo "------------------------------------------------------------"
    echo "unset http_proxy https_proxy all_proxy no_proxy"
    echo "------------------------------------------------------------"
    echo ""
    exit 0
fi

# --- 永久写入 ---

# 询问是否默认开启
read -p "是否希望每次打开新终端时自动开启代理？ (Y/n): " confirm_default_on
confirm_default_on=${confirm_default_on:-Y}

# --- 根据用户的选择生成不同的配置内容 ---
if [[ "$confirm_default_on" =~ ^[Yy]$ ]]; then
    # --- 默认开启的配置 ---
    PROXY_CONFIG_BLOCK=$(cat <<EOM
# --- PROXY-START --- Managed by setup_proxy_config.sh
# https://github.com/KroMiose/LazyCat-Scripts
#
# 代理已设置为默认开启。您可以运行 'unproxy' 在当前会话中临时关闭它。
export PROXY_HOST="${PROXY_HOST}"
export PROXY_PORT="${PROXY_PORT}"

export http_proxy="http://\${PROXY_HOST}:\${PROXY_PORT}"
export https_proxy="http://\${PROXY_HOST}:\${PROXY_PORT}"
export all_proxy="socks5://\${PROXY_HOST}:\${PROXY_PORT}"
export no_proxy="localhost,127.0.0.1,::1,*.local"

# 'proxy' 命令用于在 unproxy 之后重新开启代理
proxy() {
    export http_proxy="http://\${PROXY_HOST}:\${PROXY_PORT}"
    export https_proxy="http://\${PROXY_HOST}:\${PROXY_PORT}"
    export all_proxy="socks5://\${PROXY_HOST}:\${PROXY_PORT}"
    export no_proxy="localhost,127.0.0.1,::1,*.local"
    echo "✅ 代理已手动开启。"
}

unproxy() {
    unset http_proxy
    unset https_proxy
    unset all_proxy
    unset no_proxy
    echo "☑️  代理已关闭。"
}
# --- PROXY-END ---
EOM
)
else
    # --- 手动开启的配置 (旧逻辑) ---
    PROXY_CONFIG_BLOCK=$(cat <<EOM
# --- PROXY-START --- Managed by setup_proxy_config.sh
# https://github.com/KroMiose/LazyCat-Scripts
#
# 运行 'proxy' 来开启代理，'unproxy' 来关闭。
export PROXY_HOST="${PROXY_HOST}"
export PROXY_PORT="${PROXY_PORT}"

proxy() {
    export http_proxy="http://\${PROXY_HOST}:\${PROXY_PORT}"
    export https_proxy="http://\${PROXY_HOST}:\${PROXY_PORT}"
    export all_proxy="socks5://\${PROXY_HOST}:\${PROXY_PORT}"
    export no_proxy="localhost,127.0.0.1,::1,*.local"
    
    echo "✅ 代理已开启: http/https -> http://\${PROXY_HOST}:\${PROXY_PORT} | all -> socks5://\${PROXY_HOST}:\${PROXY_PORT}"
}

unproxy() {
    unset http_proxy
    unset https_proxy
    unset all_proxy
    unset no_proxy
    echo "☑️  代理已关闭。"
}
# --- PROXY-END ---
EOM
)
fi

# --- 检测 Shell 配置文件 ---
# 优先使用用户的默认 Shell ($SHELL)，这是用户真正在使用的 Shell
SHELL_TYPE=$(basename "$SHELL")
PROFILE_FILE=""

echo "🔍 检测到您的默认 Shell 是: $SHELL_TYPE"

if [ "$SHELL_TYPE" = "zsh" ]; then
    PROFILE_FILE="$HOME/.zshrc"
elif [ "$SHELL_TYPE" = "bash" ]; then
    PROFILE_FILE="$HOME/.bashrc"
else
    echo "⚠️ 警告: 未能识别您的 Shell 类型 ($SHELL_TYPE)。" >&2
    echo "脚本将尝试在 ~/.zshrc 和 ~/.bashrc 中寻找。" >&2
    if [ -f "$HOME/.zshrc" ]; then
        PROFILE_FILE="$HOME/.zshrc"
        echo "  -> 找到 ~/.zshrc，将使用它。"
    elif [ -f "$HOME/.bashrc" ]; then
        PROFILE_FILE="$HOME/.bashrc"
        echo "  -> 找到 ~/.bashrc，将使用它。"
    fi
fi

# 如果检测到的配置文件不存在，提供选择
if [ -n "$PROFILE_FILE" ] && [ ! -f "$PROFILE_FILE" ]; then
    echo "⚠️ 警告: 配置文件 $PROFILE_FILE 不存在。" >&2
    # 尝试查找其他可用的配置文件
    if [ -f "$HOME/.zshrc" ]; then
        echo "  -> 找到 ~/.zshrc"
        read -p "是否使用 ~/.zshrc 代替？ (Y/n): " use_alt
        use_alt=${use_alt:-Y}
        if [[ "$use_alt" =~ ^[Yy]$ ]]; then
            PROFILE_FILE="$HOME/.zshrc"
        else
            PROFILE_FILE=""
        fi
    elif [ -f "$HOME/.bashrc" ]; then
        echo "  -> 找到 ~/.bashrc"
        read -p "是否使用 ~/.bashrc 代替？ (Y/n): " use_alt
        use_alt=${use_alt:-Y}
        if [[ "$use_alt" =~ ^[Yy]$ ]]; then
            PROFILE_FILE="$HOME/.bashrc"
        else
            PROFILE_FILE=""
        fi
    fi
fi

if [ -z "$PROFILE_FILE" ]; then
    echo "❌ 错误: 找不到合适的 Shell 配置文件。" >&2
    echo "请您手动将配置添加到您的 Shell 启动文件中。" >&2
    exit 1
fi

echo "🔧 将使用配置文件: $PROFILE_FILE"

# --- 写入操作 ---
read -p "确定要将代理配置写入到 '$PROFILE_FILE' 吗？ (Y/n): " confirm_write
confirm_write=${confirm_write:-Y}

if [[ ! "$confirm_write" =~ ^[Yy]$ ]]; then
    echo "🛑 用户取消了操作。"
    exit 0
fi

# 备份
cp "$PROFILE_FILE" "${PROFILE_FILE}.bak.$(date +'%Y-%m-%d_%H-%M-%S')"
echo "  -> 已创建备份文件: ${PROFILE_FILE}.bak.*"

# 幂等性：先删除旧块
if grep -q "# --- PROXY-START ---" "$PROFILE_FILE"; then
    echo "  -> 检测到旧的代理配置，正在更新..."
    awk '
        BEGIN {p=0}
        /# --- PROXY-START ---/ {p=1; next}
        /# --- PROXY-END ---/ {p=0; next}
        !p {print}
    ' "$PROFILE_FILE" >"${PROFILE_FILE}.tmp" && mv "${PROFILE_FILE}.tmp" "$PROFILE_FILE"
fi

# 追加新块
echo "  -> 正在写入新配置..."
echo -e "\n${PROXY_CONFIG_BLOCK}" >>"$PROFILE_FILE"

# --- 完成提示 ---
echo ""
echo "========================================================================"
echo "      🎉 代理配置成功写入! 🎉"
echo "------------------------------------------------------------------------"
if [[ "$confirm_default_on" =~ ^[Yy]$ ]]; then
    echo "  代理将在新终端中自动开启。"
    echo "  您可以运行 'unproxy' 在当前会话中临时关闭它，或运行 'proxy' 重新开启。"
else
    echo "  便捷命令 'proxy' 和 'unproxy' 已添加到 '$PROFILE_FILE'"
    echo "  您可以通过运行 'proxy' 来开启代理。"
fi
echo ""
echo "  请执行最后一步以使配置生效:"
echo ""
echo "  👉 运行 'source ${PROFILE_FILE}' 或重启您的终端。"
echo ""
if [[ ! "$confirm_default_on" =~ ^[Yy]$ ]]; then
    echo "  之后，您可以随时通过以下命令来控制代理:"
    echo "    - 开启代理: proxy"
    echo "    - 关闭代理: unproxy"
fi
echo "========================================================================"

exit 0