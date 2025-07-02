#!/bin/bash

# ==============================================================================
# 脚本名称: restore_shell_backup.sh
# 功    能: 查找并恢复由本系列脚本创建的 Shell 配置文件备份。
#           它会列出所有找到的备份文件，并允许用户选择一个进行恢复。
# 适用系统: 所有主流 Linux 发行版及 macOS
# 使用方法: bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/scripts/main/linux/restore_shell_backup.sh)"
# ==============================================================================

set -e

echo "--- Shell 配置恢复工具 ---"
echo "🔎 正在扫描您的家目录以查找由我们脚本创建的备份文件..."
echo ""

# 定义要查找的备份文件模式
declare -a backup_patterns=(
    "$HOME/.zshrc.bak.*"
    "$HOME/.bashrc.bak.*"
    "$HOME/.ssh/config.bak.*"
)

# 使用 find 查找所有匹配的备份文件
backups=()
for pattern in "${backup_patterns[@]}"; do
    # 'shopt -s nullglob' ensures the loop doesn't run if no files match
    shopt -s nullglob
    for f in $pattern; do
        backups+=("$f")
    done
    shopt -u nullglob
done


if [ ${#backups[@]} -eq 0 ]; then
    echo "🤷‍♀️ 未找到任何由本系列脚本创建的备份文件。"
    echo "   备份文件通常命名为 '.zshrc.bak.2024-07-26_10-30-00' 等。"
    exit 0
fi

echo "✅ 找到了以下备份文件，请选择您想恢复的一个:"

# 打印带编号的备份列表
for i in "${!backups[@]}"; do
    backup_file="${backups[$i]}"
    # 从文件名中提取日期字符串
    datetime_str=$(echo "$backup_file" | awk -F'.bak.' '{print $2}')
    # 将日期字符串格式化为可读格式
    human_readable_date=$(echo "$datetime_str" | sed 's/_/ /')
    
    # 获取原始文件名
    original_filename=$(echo "$backup_file" | sed -E 's/\.bak\.[0-9]{4}(-[0-9]{2}){2}_([0-9]{2}-){2}[0-9]{2}$//')

    printf "  %2d) %-20s (备份于: %s)\n" "$((i+1))" "$(basename "$original_filename")" "$human_readable_date"
done

echo "  --------------------------------------------"
echo "   c) 清除所有上面列出的备份文件"
echo ""

# 提示用户选择
read -p "请输入您想恢复的备份编号, 或输入 'c' 清除所有备份 (输入 q 退出): " choice

# 验证输入
if [[ "$choice" =~ ^[qQ]$ ]] || [ -z "$choice" ]; then
    echo "操作已取消。"
    exit 0
fi

# 处理清除操作
if [[ "$choice" =~ ^[cC]$ ]]; then
    echo ""
    echo "⚠️  警告: 您将要永久删除所有 ${#backups[@]} 个备份文件。"
    echo "这是一个不可恢复的操作！"
    read -p "如果您非常确定，请输入 'delete all' 来确认: " confirm_delete
    if [[ "$confirm_delete" == "delete all" ]]; then
        echo "⏳ 正在删除所有备份文件..."
        for backup_file in "${backups[@]}"; do
            rm -f "$backup_file"
            echo "  -> 已删除: $backup_file"
        done
        echo "✅ 所有备份文件已清除。"
    else
        echo "操作已取消。"
    fi
    exit 0
fi

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
    echo "❌ 错误: 无效的选项 '${choice}'。" >&2
    exit 1
fi

selected_backup_index=$((choice-1))
selected_backup_file="${backups[$selected_backup_index]}"
original_file_to_restore=$(echo "$selected_backup_file" | sed -E 's/\.bak\.[0-9]{4}(-[0-9]{2}){2}_([0-9]{2}-){2}[0-9]{2}$//')

# 最终确认
echo ""
echo "⚠️  您确定要执行以下操作吗？"
echo "   - 备份文件: $selected_backup_file"
echo "   - 将覆盖:   $original_file_to_restore"
echo "此操作不可撤销！"
read -p "请输入 'yes' 以确认: " confirm

if [ "$confirm" != "yes" ]; then
    echo "操作已取消。"
    exit 0
fi

# 执行恢复
echo "⏳ 正在恢复..."
cp "$selected_backup_file" "$original_file_to_restore"

echo ""
echo "========================================================"
echo "      🎉 恢复成功! 🎉"
echo "--------------------------------------------------------"
echo "  文件 '$original_file_to_restore' 已被成功恢复。"
echo "  请运行 'source $original_file_to_restore' 或重启您的终端以使更改生效。"
echo "========================================================"

exit 0 