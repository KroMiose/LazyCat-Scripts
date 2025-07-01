#!/bin/bash

# ==============================================================================
# 脚本名称: setup_en_dirs.sh
# 功    能: 在保持系统语言为中文的情况下，将用户家目录下的标准文件夹
#           （如"下载"、"音乐"等）从中文名改为英文名。
# 适用系统: 基于 Debian 的系统 (Ubuntu, Debian, etc.)
# 使用方法: sudo bash setup_en_dirs.sh
# ==============================================================================

# --- 安全检查: 必须以 root 或 sudo 权限运行 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用 'sudo' 来运行此脚本。" >&2
    exit 1
fi

# --- 获取真正调用脚本的用户名 ---
# 如果使用 sudo, $USER 可能是 root, 所以用 $SUDO_USER
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
else
    echo "错误: 无法确定普通用户身份。请使用 'sudo -u <你的用户名> bash setup_en_dirs.sh' 或正常 sudo 运行。" >&2
    exit 1
fi

# 获取用户家目录
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

if [ ! -d "$USER_HOME" ]; then
    echo "错误: 无法找到用户 '$REAL_USER' 的家目录: $USER_HOME" >&2
    exit 1
fi

echo "正在为用户 '$REAL_USER' 配置英文目录..."

# --- 步骤 1: 备份旧的配置文件 ---
CONFIG_FILE="$USER_HOME/.config/user-dirs.dirs"
if [ -f "$CONFIG_FILE" ]; then
    echo "备份旧的配置文件到 $CONFIG_FILE.bak"
    # 必须以用户身份执行，否则备份文件的所有者会是 root
    sudo -u "$REAL_USER" cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
fi

# --- 步骤 2: 写入新的英文目录配置 ---
echo "正在更新配置文件: $CONFIG_FILE"
# 使用 sudo -u 来确保创建的文件属于目标用户
sudo -u "$REAL_USER" bash -c "cat > '$CONFIG_FILE'" <<EOF
# This file is written by xdg-user-dirs-update
# If you want to change or add directories, just edit the line you're
# interested in. All local changes will be preserved.
# Format is XDG_xxx_DIR="\$HOME/yyy", where yyy is a shell-escaped
# homedir-relative path, or a full path starting with /
XDG_DESKTOP_DIR="\$HOME/Desktop"
XDG_DOWNLOAD_DIR="\$HOME/Downloads"
XDG_TEMPLATES_DIR="\$HOME/Templates"
XDG_PUBLICSHARE_DIR="\$HOME/Public"
XDG_DOCUMENTS_DIR="\$HOME/Documents"
XDG_MUSIC_DIR="\$HOME/Music"
XDG_PICTURES_DIR="\$HOME/Pictures"
XDG_VIDEOS_DIR="\$HOME/Videos"
EOF

# --- 步骤 3: 禁止系统自动更新目录配置 ---
# 这是防止系统在下次登录时把配置改回中文的关键步骤
XDG_CONF_FILE="/etc/xdg/user-dirs.conf"
if [ -f "$XDG_CONF_FILE" ]; then
    echo "正在禁用 user-dirs 自动更新..."
    # 使用 sed 将 enabled=True 改为 enabled=False
    sed -i 's/enabled=True/enabled=False/g' "$XDG_CONF_FILE"
else
    echo "警告: 找不到 $XDG_CONF_FILE。可能无法禁用自动更新。"
fi

# --- 步骤 4: 强制更新并创建新目录 ---
# 以用户身份运行 xdg-user-dirs-update 来根据新配置创建目录
echo "正在创建新的英文目录..."
sudo -u "$REAL_USER" xdg-user-dirs-update --force

# --- 步骤 5: 迁移文件并删除旧目录 ---
echo "开始迁移文件..."

# 定义中英文目录对应关系
declare -A DIRS_MAP
DIRS_MAP=(
    ["$USER_HOME/桌面"]="$USER_HOME/Desktop"
    ["$USER_HOME/下载"]="$USER_HOME/Downloads"
    ["$USER_HOME/模板"]="$USER_HOME/Templates"
    ["$USER_HOME/公共"]="$USER_HOME/Public"
    ["$USER_HOME/文档"]="$USER_HOME/Documents"
    ["$USER_HOME/音乐"]="$USER_HOME/Music"
    ["$USER_HOME/图片"]="$USER_HOME/Pictures"
    ["$USER_HOME/视频"]="$USER_HOME/Videos"
)

for old_dir in "${!DIRS_MAP[@]}"; do
    new_dir=${DIRS_MAP[$old_dir]}
    if [ -d "$old_dir" ]; then
        echo "处理目录: $old_dir -> $new_dir"
        # 确保目标目录存在
        if [ ! -d "$new_dir" ]; then
            sudo -u "$REAL_USER" mkdir -p "$new_dir"
        fi
        # 使用 mv -n (no-clobber) 安全地移动文件，避免覆盖
        # 将旧目录中的所有内容（包括隐藏文件）移动到新目录
        if [ -n "$(ls -A "$old_dir")" ]; then
            echo "  -> 正在移动文件..."
            sudo -u "$REAL_USER" mv -n "$old_dir"/* "$old_dir"/.* "$new_dir"/ 2>/dev/null
        fi
        # 删除空的旧目录
        # 使用 rmdir, 如果目录非空则会失败，更安全
        if sudo -u "$REAL_USER" rmdir "$old_dir" 2>/dev/null; then
            echo "  -> 成功删除空的旧目录: $old_dir"
        else
            if [ -d "$old_dir" ]; then
                echo "  -> 警告: 目录 $old_dir 迁移后非空，未删除。"
            fi
        fi
    fi
done

echo ""
echo "========================================================"
echo "      配置完成!"
echo "--------------------------------------------------------"
echo "  - 用户目录已配置为英文。"
echo "  - 原中文目录下的文件已迁移到新目录。"
echo "  - 系统不会在下次登录时自动改回中文目录。"
echo ""
echo "  >>> 请您注销并重新登录系统以使所有更改完全生效 <<<"
echo "========================================================"

exit 0
