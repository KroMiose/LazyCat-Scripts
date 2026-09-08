#!/usr/bin/env bash
# Offline read-only inspection by default; never sources metadata or connects SSH.
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
json_string() {
    local value="$1" i ch code LC_ALL=C
    printf '"'
    for ((i=0;i<${#value};i++)); do
        ch="${value:i:1}"
        case "$ch" in
            '"') printf '\\"' ;;
            '\') printf '\\\\' ;;
            *) printf -v code '%d' "'$ch"
               if ((code>=0 && code<32)); then printf '\\u%04x' "$code";else printf '%s' "$ch";fi ;;
        esac
    done
    printf '"'
}
if [[ "${1:-}" == recover-lock ]]; then
    [[ $# == 2 ]] || { echo 'recover-lock <目标文件绝对路径>' >&2; exit 2; }
    lc_tx_recover_lock "$2"
    exit
fi
if [[ "${1:-}" == rollback ]]; then
    [[ $# == 2 && -d "$2" && ! -L "$2" ]] || { echo 'rollback <操作记录绝对目录>' >&2; exit 2; }
    operation="$2"
    IFS= read -r target < "$operation/target"
    [[ "$operation" == "$target".lazycat-operation.* && "$target" == /* ]] || { echo '记录与目标不匹配' >&2; exit 3; }
    lc_tx_check_path "$operation" || exit 3
    for record in target before after existed status; do
        [[ -f "$operation/$record" && ! -L "$operation/$record" ]] || { echo 'Invalid operation record' >&2; exit 3; }
    done
    IFS= read -r existed < "$operation/existed"
    IFS= read -r status < "$operation/status"
    case "$existed:$status" in
        0:prepared|1:prepared|0:committed|1:committed|0:rolled-back|1:rolled-back) ;;
        *) echo 'Invalid operation state' >&2; exit 3 ;;
    esac
    trap 'lc_tx_unlock' EXIT
    lc_tx_begin "$target"
    # Read under the same lock used by writers. An uncommitted candidate, or a
    # rollback interrupted after restoration, can already be in its old state.
    restored=0
    if [[ "$existed" == 0 && "$LC_TX_EXISTED" == 0 ]]; then
        restored=1
    elif [[ "$existed" == 1 && "$LC_TX_EXISTED" == 1 ]] &&
        cmp -s "$LC_TX_OPERATION/before" "$operation/before" &&
        [[ "$LC_TX_METADATA" == "$(LC_ALL=C ls -ldn "$operation/before" | awk '{print $1, $3, $4}')" ]]; then
        restored=1
    fi
    if [[ "$restored" == 1 ]]; then
        printf 'rolled-back\n' > "$operation/status"
        rm -rf "$LC_TX_OPERATION"
        lc_tx_unlock
        exit 0
    fi
    if [[ "$status" == rolled-back || "$LC_TX_EXISTED" != 1 ]] ||
        ! cmp -s "$LC_TX_OPERATION/before" "$operation/after" ||
        [[ "$LC_TX_METADATA" != "$(LC_ALL=C ls -ldn "$operation/after" | awk '{print $1, $3, $4}')" ]]; then
        rm -rf "$LC_TX_OPERATION"
        echo 'Target changed since operation; refusing rollback' >&2
        exit 3
    fi
    lc_tx_copy "$LC_TX_CANDIDATE" "$operation/rollback-current"
    IFS= read -r existed < "$operation/existed"
    if [[ "$existed" == 1 ]]; then
        lc_tx_copy "$operation/before" "$LC_TX_CANDIDATE"
        lc_tx_commit
    elif [[ "$existed" == 0 ]]; then
        cmp -s "$target" "$LC_TX_OPERATION/before" || exit 3
        rm "$target"
        printf 'removed-by-rollback\n' > "$LC_TX_OPERATION/status"
        lc_tx_unlock
    else
        echo '记录损坏' >&2; exit 3
    fi
    printf 'rolled-back\n' > "$operation/status"
    exit 0
fi
[[ $# == 0 || ( $# == 1 && "$1" == --json ) ]] || { echo '用法：lazycat-check.sh [--json] | rollback <操作目录> | recover-lock <目标文件绝对路径>' >&2; exit 2; }
shopt -s nullglob
scan_dirs=("$HOME" "$HOME/.ssh" "$HOME/.ssh/lazycat-hosts" "${XDG_CONFIG_HOME:-$HOME/.config}")
if [[ "$EUID" == 0 ]]; then scan_dirs+=(/etc/squid /etc/systemd/system/docker.service.d); fi
operations=()
for scan_dir in "${scan_dirs[@]}"; do
    [[ -d "$scan_dir" ]] || continue
    lc_tx_check_path "$scan_dir" >/dev/null 2>&1 || continue
    operations+=("$scan_dir"/*.lazycat-operation.* "$scan_dir"/.*.lazycat-operation.*)
done
printf '{"format_version":1,"read_only":true,"network":"not checked","operations":['
separator=''
for operation in "${operations[@]:-}"; do
    [[ -d "$operation" && ! -L "$operation" ]] || continue
    status=unknown
    if [[ ! -L "$operation/status" && -f "$operation/status" ]]; then
        if ! IFS= read -r status < "$operation/status"; then
            [[ -n "$status" ]] || status=unknown
        fi
    fi
    printf '%s{"path":' "$separator"; json_string "$operation"
    printf ',"status":'; json_string "$status"; printf '}'
    separator=,
done
printf '],"limitations":["Only known HOME, SSH, XDG and root service directories are scanned; symlink directories are not followed","Go SSH journals require lazycat-ssh doctor --json","Legacy backups are not proof of ownership","Service behavior and credentials are not tested"]}\n'
