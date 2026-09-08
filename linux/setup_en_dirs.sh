#!/usr/bin/env bash
# User-scoped XDG migration. Default: review only. Never edits /etc/xdg.
set -euo pipefail
# lazycat-file-transaction:begin
# Single-file candidate/backup protocol. Embedded into standalone release scripts.
# Call lc_tx_begin, edit "$LC_TX_CANDIDATE", validate, then lc_tx_commit.
lc_tx_copy() {
    # GNU cp -p preserves modes/ACLs but silently drops user xattrs. Request
    # xattr explicitly (rather than --preserve=all, which tolerates failures).
    case "$(uname -s)" in
        Linux) cp --preserve=mode,ownership,timestamps,xattr -- "$1" "$2" ;;
        Darwin) cp -p "$1" "$2" ;;
        *) echo '未验证的文件属性复制平台，未提交修改' >&2; return 1 ;;
    esac
}
lc_tx_check_path() {
    local parent="$1"
    while [[ -n "$parent" && "$parent" != / ]]; do
        if [[ -L "$parent" ]]; then
            case "$parent" in
                /var|/tmp|/etc) [[ "$(uname -s)" == Darwin && "$parent" != "$1" ]] || { echo '路径包含符号链接，需要先明确采纳' >&2; return 3; } ;;
                *) echo '路径包含符号链接，需要先明确采纳' >&2; return 3 ;;
            esac
        fi
        parent="${parent%/*}"
    done
}
lc_tx_begin() {
    LC_TX_TARGET="$1"
    [[ "$LC_TX_TARGET" == /* && "$LC_TX_TARGET" != *$'\n'* && "$LC_TX_TARGET" != *$'\r'* ]] || { echo '事务目标必须是绝对单行路径' >&2; return 2; }
    lc_tx_check_path "$LC_TX_TARGET" || return 3
    LC_TX_LOCK="${LC_TX_TARGET}.lazycat-lock"
    LC_TX_LOCK_OWNED=0
    [[ ! -e "${LC_TX_LOCK}.recovery" && ! -L "${LC_TX_LOCK}.recovery" ]] || { echo '锁恢复正在进行或中断，请检查恢复记录' >&2; return 3; }
    (umask 077; mkdir "$LC_TX_LOCK") || { echo "操作锁已存在，请检查并发或中断状态：$LC_TX_LOCK" >&2; return 3; }
    LC_TX_LOCK_OWNED=1
    printf '%s\n' "$$" > "$LC_TX_LOCK/pid"
    if [[ -e "${LC_TX_LOCK}.recovery" || -L "${LC_TX_LOCK}.recovery" ]]; then lc_tx_unlock; echo '锁恢复与新操作冲突，未写入目标' >&2; return 3; fi
    LC_TX_OPERATION=$(mktemp -d "${LC_TX_TARGET}.lazycat-operation.XXXXXX")
    chmod 700 "$LC_TX_OPERATION"
    printf '%s\n' "$LC_TX_TARGET" > "$LC_TX_OPERATION/target"
    LC_TX_EXISTED=0
    if [[ -e "$LC_TX_TARGET" ]]; then
        [[ -f "$LC_TX_TARGET" ]] || { lc_tx_unlock; echo '目标不是普通文件' >&2; return 3; }
        LC_TX_EXISTED=1
        LC_TX_METADATA=$(LC_ALL=C ls -ldn "$LC_TX_TARGET" | awk '{print $1, $3, $4}')
        printf '%s\n' "$LC_TX_METADATA" > "$LC_TX_OPERATION/metadata"
        lc_tx_copy "$LC_TX_TARGET" "$LC_TX_OPERATION/before" || { lc_tx_unlock; return 1; }
    else
        (umask 077; : > "$LC_TX_OPERATION/before")
    fi
    LC_TX_METADATA=$(LC_ALL=C ls -ldn "$LC_TX_OPERATION/before" | awk '{print $1, $3, $4}')
    printf '%s\n' "$LC_TX_METADATA" > "$LC_TX_OPERATION/metadata"
    printf '%s\n' "$LC_TX_EXISTED" > "$LC_TX_OPERATION/existed"
    lc_tx_copy "$LC_TX_OPERATION/before" "$LC_TX_OPERATION/after" || { lc_tx_unlock; return 1; }
    LC_TX_CANDIDATE="$LC_TX_OPERATION/after"
    printf 'prepared\n' > "$LC_TX_OPERATION/status"
}
# Explicit stale-lock recovery. A live/reused PID, incomplete lock or competing
# recovery is a conflict. Keep the original lock as evidence; never delete it.
lc_tx_recover_lock() (
    set -e
    local target="$1" lock guard pid archived process result
    [[ "$target" == /* && "$target" != *$'\n'* && "$target" != *$'\r'* ]] || return 2
    lc_tx_check_path "$target" || return 3
    lock="${target}.lazycat-lock"
    guard="${lock}.recovery"
    [[ -d "$lock" && ! -L "$lock" && -f "$lock/pid" && ! -L "$lock/pid" ]] || { echo '锁缺失、损坏或为链接，需人工检查' >&2; return 3; }
    (umask 077; mkdir "$guard") || return 3
    trap 'rmdir "$guard"' EXIT
    IFS= read -r pid < "$lock/pid"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo '锁的 PID 无效，未移动' >&2; return 3; }
    # ps also sees processes which kill -0 cannot probe due to permissions.
    result=0
    process=$(LC_ALL=C ps -p "$pid" -o pid=) || result=$?
    [[ "$result" == 1 && -z "$process" ]] || { echo '锁的进程仍存在或无法确认，未移动' >&2; return 3; }
    archived=$(mktemp -d "${lock}.recovered.XXXXXX")
    chmod 700 "$archived"
    mv "$lock" "$archived/lock"
    printf '已保存失效锁：%s\n目标与事务备份未修改；请检查后回滚或重新执行。\n' "$archived"
)
lc_tx_unlock() {
    [[ -n "${LC_TX_LOCK:-}" && "${LC_TX_LOCK_OWNED:-0}" == 1 ]] || return 0
    rm -f "$LC_TX_LOCK/pid"
    rmdir "$LC_TX_LOCK"
    LC_TX_LOCK=''
    LC_TX_LOCK_OWNED=0
}
lc_tx_commit() {
    lc_tx_check_path "$LC_TX_TARGET" || return 3
    if [[ "$LC_TX_EXISTED" == 1 ]]; then
        [[ "$(LC_ALL=C ls -ldn "$LC_TX_TARGET" | awk '{print $1, $3, $4}')" == "$LC_TX_METADATA" ]] || { echo '文件权限或属主被并发修改' >&2; return 3; }
        cmp -s "$LC_TX_TARGET" "$LC_TX_OPERATION/before" || { echo '检测到并发修改，已停止' >&2; return 3; }
    else
        [[ ! -e "$LC_TX_TARGET" ]] || { echo '目标被并发创建，已停止' >&2; return 3; }
    fi
    if [[ "$LC_TX_EXISTED" == 1 && "$(LC_ALL=C ls -ldn "$LC_TX_CANDIDATE" | awk '{print $1, $3, $4}')" == "$LC_TX_METADATA" ]] && cmp -s "$LC_TX_CANDIDATE" "$LC_TX_OPERATION/before"; then
        rm -rf "$LC_TX_OPERATION"
        lc_tx_unlock
        return 0
    fi
    local staged
    staged=$(mktemp "${LC_TX_TARGET}.lazycat-stage.XXXXXX")
    lc_tx_copy "$LC_TX_CANDIDATE" "$staged" || { rm -f "$staged"; return 1; }
    if ! mv "$staged" "$LC_TX_TARGET"; then rm -f "$staged"; return 1; fi
    printf 'committed\n' > "$LC_TX_OPERATION/status"
    lc_tx_unlock
    printf '操作记录与备份：%s\n' "$LC_TX_OPERATION"
}
lc_remove_block_candidate() {
    local file="$1" begin="$2" end="$3" tmp
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { if (inside || seen++) bad=1; inside=1 }
        $0 == end { if (!inside) bad=1; inside=0 }
        END { exit (bad || inside) ? 1 : 0 }
    ' "$file" || { echo '托管标记损坏，未修改目标文件' >&2; return 3; }
    tmp=$(mktemp "${file}.XXXXXX")
    lc_tx_copy "$file" "$tmp" || { rm -f "$tmp"; return 1; }
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { inside=1; next }
        $0 == end { inside=0; next }
        !inside { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}
# lazycat-file-transaction:end
if [[ "$EUID" == 0 ]]; then
    [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root && -f "${BASH_SOURCE[0]:-}" ]] || { echo '请以目标普通用户运行本地脚本' >&2; exit 2; }
    exec sudo -H -u "$SUDO_USER" bash "${BASH_SOURCE[0]}" "$@"
fi
apply=0
move_files=0
for arg in "$@"; do
    case "$arg" in --check) ;; --apply) apply=1 ;; --move-files) move_files=1 ;; *) echo '用法：[--check | --apply [--move-files]]' >&2; exit 2 ;; esac
done
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
config="$config_dir/user-dirs.dirs"
[[ -f "$config" && ! -L "$config" && ! -L "$config_dir" ]] || { echo '缺少可直接编辑的用户 XDG 配置；未修改' >&2; exit 3; }
keys=(DESKTOP DOWNLOAD TEMPLATES PUBLICSHARE DOCUMENTS MUSIC PICTURES VIDEOS)
names=(Desktop Downloads Templates Public Documents Music Pictures Videos)
sources=()
targets=()
for ((i=0;i<${#keys[@]};i++)); do
    field="XDG_${keys[$i]}_DIR"
    value=$(awk -v field="$field" 'index($0,field "=")==1 {count++;value=substr($0,length(field)+2)} END {if(count!=1) exit 1; print value}' "$config") || { echo "$field 缺失或重复" >&2; exit 3; }
    [[ "$value" == \"*\" ]] || { echo "$field 不是受支持的数据格式" >&2; exit 3; }
    value=${value#\"};value=${value%\"}
    if [[ "$value" == '$HOME' || "$value" == '$HOME/'* ]]; then value="$HOME${value#\$HOME}"; fi
    [[ "$value" == /* && "$value" != *['$`\"']* && "$value" != *$'\n'* ]] || { echo "$field 包含需人工审阅的表达式" >&2; exit 3; }
    target="$HOME/${names[$i]}"
    # XDG uses HOME to explicitly disable a user directory; preserve that choice.
    [[ "$value" != "$HOME" ]] || target="$HOME"
    sources+=("$value");targets+=("$target")
    printf '%s: %s -> %s\n' "$field" "$value" "$target"
    if [[ "$value" != "$target" ]]; then
        [[ ! -L "$value" && ! -L "$target" && ! -e "$target" ]] || { echo '目标冲突或符号链接，全部迁移已停止' >&2; exit 3; }
        if [[ -e "$value" && "$move_files" != 1 && "$apply" == 1 ]]; then echo '有原目录，应用需显式 --move-files；未搬迁或写配置' >&2; exit 3; fi
    fi
done
[[ "$apply" == 1 ]] || { echo '只读检查完成。未搬迁文件，未修改任何配置。'; exit 0; }
applied_sources=()
applied_targets=()
config_committed=0
xdg_finish() {
    local result=$? j
    trap - EXIT
    if [[ "$result" != 0 && "$config_committed" == 0 ]]; then
        for ((j=${#applied_targets[@]}-1;j>=0;j--)); do
            if [[ -n "${applied_sources[$j]}" ]]; then
                if [[ ! -e "${applied_sources[$j]}" && ! -L "${applied_sources[$j]}" ]]; then
                    mv -T -n "${applied_targets[$j]}" "${applied_sources[$j]}" || echo '目录恢复失败，保留操作记录' >&2
                else
                    echo '恢复位置出现新内容，未覆盖；请查看目录移动记录' >&2
                fi
            else
                rmdir "${applied_targets[$j]}" || echo '新目录已有内容，已保留' >&2
            fi
        done
    fi
    lc_tx_unlock
    exit "$result"
}
trap xdg_finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
lc_tx_begin "$config"
# Produce settings without evaluating the original file as shell code.
for ((i=0;i<${#keys[@]};i++)); do
    field="XDG_${keys[$i]}_DIR";target="${targets[$i]}"
    target=${target/#$HOME/\$HOME}
    LC_FIELD="$field" LC_VALUE="$target" awk 'index($0,ENVIRON["LC_FIELD"] "=")==1 {print ENVIRON["LC_FIELD"] "=\"" ENVIRON["LC_VALUE"] "\"";next} {print}' "$LC_TX_CANDIDATE" > "$LC_TX_OPERATION/rewrite"
    cat "$LC_TX_OPERATION/rewrite" > "$LC_TX_CANDIDATE"
done
# Moving directories is an explicitly separate, journalled operation. Refuse
# cross-device moves, where mv could silently become copy/delete.
for ((i=0;i<${#keys[@]};i++)); do
    source="${sources[$i]}";target="${targets[$i]}"
    [[ "$source" != "$target" ]] || continue
    if [[ -d "$source" ]]; then
        [[ "$(stat -c %d "$source")" == "$(stat -c %d "$HOME")" ]] || { echo '跨文件系统迁移需要单独处理；查看操作记录' >&2; exit 3; }
        printf '%s\t%s\n' "$source" "$target" >> "$LC_TX_OPERATION/directory-moves"
        mv -T -n "$source" "$target"
        applied_sources+=("$source");applied_targets+=("$target")
        [[ ! -e "$source" && -d "$target" ]] || { echo '目录移动未完成；查看操作记录，未写入新配置' >&2; exit 1; }
    else
        mkdir "$target"
        applied_sources+=("");applied_targets+=("$target")
    fi
done
lc_tx_commit
config_committed=1
echo '用户目录设置已提交；未修改系统级 XDG 设置。目录移动记录需单独审阅后回退。'
