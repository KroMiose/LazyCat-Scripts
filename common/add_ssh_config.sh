#!/usr/bin/env bash
# Add an independent owned SSH fragment; never parse-and-delete old Host blocks.
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
# inode plus nanosecond ctime detects metadata-only edits (including ACL/xattr)
# without adding Python/getfattr as an installation dependency.
lc_tx_revision() {
    case "$(uname -s)" in
        Linux) LC_ALL=C stat -c '%d:%i:%z' -- "$1" ;;
        Darwin) LC_ALL=C stat -f '%d:%i:%Fc' "$1" ;;
        *) return 1 ;;
    esac
}
lc_tx_check_revision() {
    lc_tx_check_path "$LC_TX_TARGET" || return 3
    if [[ "$LC_TX_EXISTED" == 1 ]]; then
        [[ -f "$LC_TX_TARGET" && "$(lc_tx_revision "$LC_TX_TARGET")" == "$LC_TX_REVISION" ]] || { echo '文件或属性被并发修改，已停止' >&2; return 3; }
    else
        [[ ! -e "$LC_TX_TARGET" && ! -L "$LC_TX_TARGET" ]] || { echo '目标被并发创建，已停止' >&2; return 3; }
    fi
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
        LC_TX_REVISION=$(lc_tx_revision "$LC_TX_TARGET") || { lc_tx_unlock; return 1; }
        LC_TX_METADATA=$(LC_ALL=C ls -ldn "$LC_TX_TARGET" | awk '{print $1, $3, $4}')
        printf '%s\n' "$LC_TX_METADATA" > "$LC_TX_OPERATION/metadata"
        lc_tx_copy "$LC_TX_TARGET" "$LC_TX_OPERATION/before" || { lc_tx_unlock; return 1; }
    else
        (umask 077; : > "$LC_TX_OPERATION/before")
    fi
    lc_tx_check_revision || { lc_tx_unlock; return 3; }
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
    lc_tx_check_revision || return 3
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
    lc_tx_check_revision || { rm -f "$staged"; return 3; }
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
alias_value='';hostname_value='';user_value='';port=22;identity='';allow_includes=0
if [[ $# == 0 ]]; then
    read -r -p '服务器别名: ' alias_value
    read -r -p 'IP 或主机名: ' hostname_value
    read -r -p '登录用户: ' user_value
    read -r -p '端口 [22]: ' port;port=${port:-22}
    read -r -p '已有私钥绝对路径（留空使用现有 SSH/agent 选择，不导入私钥）: ' identity
else
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --alias|--host|--user|--port|--identity)
                [[ $# -ge 2 ]] || exit 2
                case "$1" in --alias) alias_value="$2" ;; --host) hostname_value="$2" ;; --user) user_value="$2" ;; --port) port="$2" ;; --identity) identity="$2" ;; esac
                shift 2 ;;
            --allow-existing-includes) allow_includes=1;shift ;;
            *) echo '用法：--alias NAME --host HOST --user USER [--port PORT] [--identity PATH] [--allow-existing-includes]' >&2;exit 2 ;;
        esac
    done
fi
[[ "$alias_value" =~ ^[A-Za-z0-9._-]+$ && "$alias_value" != -* && "$alias_value" != . && "$alias_value" != .. ]] || exit 2
[[ "$hostname_value" =~ ^[A-Za-z0-9._:%-]+$ && "$hostname_value" != -* ]] || exit 2
[[ "$user_value" =~ ^[A-Za-z0-9._-]+$ && "$user_value" != -* ]] || exit 2
[[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port>0 && 10#$port<=65535)) || exit 2
if [[ -n "$identity" ]]; then
    [[ "$identity" == /* && -f "$identity" && "$identity" != *$'\n'* && "$identity" != *$'\r'* ]] || { echo '私钥路径无效；未改动原密钥' >&2;exit 2; }
fi
config="$HOME/.ssh/config"
folder="$HOME/.ssh/lazycat-hosts"
fragment="$folder/$alias_value.conf"
receipt="$folder/$alias_value.receipt"
begin='# --- LAZYCAT HOSTS START ---'
end='# --- LAZYCAT HOSTS END ---'
escaped=${folder//\\/\\\\};escaped=${escaped//\"/\\\"}
include_line="Include \"${escaped}/*.conf\""
host_include_present() {
    local line inside=0 seen=0 includes=0
    [[ -f "$1" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$begin")
                [[ "$inside" == 0 && "$seen" == 0 ]] || return 3
                inside=1;seen=1 ;;
            "$end")
                [[ "$inside" == 1 && "$includes" == 1 ]] || return 3
                inside=0 ;;
            *)
                if [[ "$inside" == 1 ]]; then
                    [[ "$line" == "$include_line" && "$includes" == 0 ]] || return 3
                    includes=1
                fi ;;
        esac
    done < "$1"
    [[ "$inside" == 0 ]] || return 3
    [[ "$seen" == 1 ]]
}
include_status=0
host_include_present "$config" || include_status=$?
[[ "$include_status" != 3 ]] || { echo 'Include 托管块损坏或有手改内容，未修改配置' >&2; exit 3; }
if [[ -f "$config" ]]; then
    if awk -v alias="$alias_value" 'tolower($1)=="host" {for(i=2;i<=NF;i++) if($i==alias) found=1} END{exit !found}' "$config"; then
        echo '旧主配置已有同名 Host；未删除或覆盖，请先审阅迁移。' >&2;exit 3
    fi
    if [[ "$allow_includes" == 0 ]] && awk '
        $0=="# --- LAZYCAT HOSTS START ---" {owned=1;next}
        $0=="# --- LAZYCAT HOSTS END ---" {owned=0;next}
        !owned && tolower($1)=="include" {found=1}
        END {exit !found}
    ' "$config"; then
        echo '主配置包含外部 Include，无法证明没有同名条目；审阅后可显式 --allow-existing-includes。' >&2;exit 3
    fi
fi
[[ ! -L "$HOME/.ssh" && ! -L "$folder" && ! -L "$receipt" && ! -L "$fragment" && ! -L "$config" ]] || { echo '符号链接需要人工采纳' >&2;exit 3; }
if [[ -e "$fragment" ]]; then
    [[ -f "$receipt" ]] && cmp -s "$fragment" "$receipt" || { echo '既有片段没有匹配的归属记录或已被修改' >&2;exit 3; }
fi
(umask 077;mkdir -p "$folder")
# Keep every completed file operation available for recovery until all commit.
committed=0
operations=()
host_finish() {
    local result=$? j op target existed
    trap - EXIT
    lc_tx_unlock
    if [[ "$committed" == 0 ]]; then
        for ((j=${#operations[@]}-1;j>=0;j--)); do
            op="${operations[$j]}"
            [[ -d "$op" ]] || continue
            IFS= read -r target < "$op/target"
            if [[ ! -L "$target" ]] && cmp -s "$target" "$op/after"; then
                IFS= read -r existed < "$op/existed"
                if [[ "$existed" == 1 ]]; then cp -p "$op/before" "$op/restore";mv "$op/restore" "$target";else rm "$target";fi
                printf 'rolled-back\n' > "$op/status"
            else
                printf 'rollback-required\n' > "$op/status"
                echo "恢复发现后续修改，保留现场：$op" >&2
            fi
        done
    fi
    exit "$result"
}
trap host_finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
lc_tx_begin "$fragment"
{
    printf '# Managed by LazyCat Host entry\nHost %s\n    HostName %s\n    User %s\n    Port %s\n' "$alias_value" "$hostname_value" "$user_value" "$((10#$port))"
    if [[ -n "$identity" ]]; then
        escaped=${identity//\\/\\\\};escaped=${escaped//\"/\\\"}
        printf '    IdentityFile "%s"\n    IdentitiesOnly yes\n' "$escaped"
    fi
} > "$LC_TX_CANDIDATE"
# Only the generated fragment is parsed; never evaluate Match exec in user config.
ssh -G -F "$LC_TX_CANDIDATE" "$alias_value" >/dev/null
operations+=("$LC_TX_OPERATION")
lc_tx_commit
lc_tx_begin "$receipt"
cat "$fragment" > "$LC_TX_CANDIDATE"
operations+=("$LC_TX_OPERATION")
lc_tx_commit
lc_tx_begin "$config"
include_status=0
host_include_present "$LC_TX_CANDIDATE" || include_status=$?
case "$include_status" in
    0) : ;; # Existing Include retains its exact position and SSH precedence.
    1)
        lc_tx_copy "$LC_TX_CANDIDATE" "$LC_TX_OPERATION/remainder"
        {
            printf '%s\n%s\n%s\n' "$begin" "$include_line" "$end"
            cat "$LC_TX_OPERATION/remainder"
        } > "$LC_TX_CANDIDATE"
        ;;
    *) echo 'Include 托管块被并发修改，停止提交' >&2; exit 3 ;;
esac
operations+=("$LC_TX_OPERATION")
lc_tx_commit
committed=1
printf 'Host %s 已写入独立片段。原密钥、旧 Host 块和其他配置已保留。\n' "$alias_value"
