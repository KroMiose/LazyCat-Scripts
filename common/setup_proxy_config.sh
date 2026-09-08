#!/usr/bin/env bash
# Shell proxy configuration. Credentials must be URL-encoded by their owner.
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
[[ "$EUID" != 0 ]] || { echo '请以普通用户运行' >&2; exit 2; }
PROXY_URL="${http_proxy:-${https_proxy:-${HTTP_PROXY:-${HTTPS_PROXY:-}}}}"
SOCKS_URL="${all_proxy:-${ALL_PROXY:-}}"
case "$SOCKS_URL" in socks5://*|socks5h://*) ;; *) SOCKS_URL='' ;; esac
PROFILE_FILE="$HOME/.bashrc"
[[ "${SHELL:-}" != */zsh ]] || PROFILE_FILE="$HOME/.zshrc"
DEFAULT_ON='preserve'
MODE=interactive
TEST=0
TEST_URL=http://ifconfig.me
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url|--socks-url|--file|--default|--test-url)
            [[ $# -ge 2 ]] || exit 2
            case "$1" in
                --url) PROXY_URL="$2" ;; --socks-url) SOCKS_URL="$2" ;;
                --file) PROFILE_FILE="$2" ;; --default) DEFAULT_ON="$2" ;;
                --test-url) TEST_URL="$2" ;;
            esac
            shift 2 ;;
        --apply) MODE=apply; shift ;;
        --print) MODE=print; shift ;;
        --test) TEST=1; shift ;;
        --help)
            echo 'setup_proxy_config.sh [--url URL] [--socks-url URL] [--file PATH] [--default on|off] [--test] [--apply|--print]'
            exit 0 ;;
        *) echo '未知参数' >&2; exit 2 ;;
    esac
done
validate_url() {
    local url="$1" authority hostport host port userinfo=''
    [[ "$url" != *[[:space:]]* && "$url" != *$'\177'* ]] || return 2
    case "$url" in http://*|https://*|socks5://*|socks5h://*) ;; *) return 2 ;; esac
    authority=${url#*://}
    [[ "$authority" != *[/?\#]* ]] || return 2
    hostport="$authority"
    if [[ "$authority" == *@* ]]; then
        userinfo=${authority%@*}; hostport=${authority##*@}
        [[ "$userinfo" != *@* && "$userinfo" =~ ^[A-Za-z0-9._~:%+-]+$ ]] || return 2
    fi
    if [[ "$hostport" == \[* ]]; then
        [[ "$hostport" == *\]:* ]] || return 2
        host=${hostport%%\]*}; host=${host#\[}; port=${hostport##*\]:}
        [[ "$host" == *:* && "$host" =~ ^[0-9A-Fa-f:]+$ ]] || return 2
    else
        host=${hostport%:*}; port=${hostport##*:}
        [[ "$host" != "$hostport" && "$host" =~ ^[A-Za-z0-9._-]+$ && "$host" != -* ]] || return 2
    fi
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port>0 && 10#$port<=65535))
}
perform_tests() {
    local url="${PROXY_URL:-http://$1:$2}" response
    if ! response=$(curl --proxy "$url" --noproxy '' --connect-timeout 5 --max-time 10 -fsS "${TEST_URL:-http://ifconfig.me}"); then
        return 2
    fi
    [[ -n "$response" ]] || return 2
    if [[ -n "${SOCKS_URL:-}" ]]; then
        curl --proxy "$SOCKS_URL" --noproxy '' --connect-timeout 5 --max-time 10 -fsS "${TEST_URL:-http://ifconfig.me}" >/dev/null || return 1
    fi
}
if [[ "$MODE" == interactive ]]; then
    echo '输入完整代理 URL，认证信息请 URL 编码；留空保留当前地址。'
    read -r -p '代理 URL [默认 http://127.0.0.1:7890]: ' input
    PROXY_URL=${input:-${PROXY_URL:-http://127.0.0.1:7890}}
    read -r -p '测试代理？[Y/n]: ' input
    [[ "$input" =~ ^[Nn]$ ]] || TEST=1
fi
[[ -n "$PROXY_URL" ]] && validate_url "$PROXY_URL" || { echo '代理 URL 无效（协议、认证编码、主机或端口）' >&2; exit 2; }
if [[ -n "$SOCKS_URL" ]]; then
    case "$SOCKS_URL" in socks5://*|socks5h://*) ;; *) echo 'SOCKS URL 协议无效' >&2; exit 2 ;; esac
    validate_url "$SOCKS_URL" || exit 2
fi
case "$DEFAULT_ON" in on|off|preserve) ;; *) exit 2 ;; esac
if [[ "$TEST" == 1 ]]; then
    test_result=0
    perform_tests '' '' || test_result=$?
    if [[ "$test_result" != 0 ]]; then
        echo "代理行为验证失败（$test_result），配置尚未写入。" >&2
        [[ "$MODE" == interactive ]] || exit 1
        read -r -p '仍然配置？[y/N]: ' input
        [[ "$input" =~ ^[Yy]$ ]] || exit 0
    fi
fi
if [[ "$MODE" == interactive ]]; then
    read -r -p '写入配置或仅打印命令？[P/t]: ' input
    if [[ "$input" =~ ^[Tt]$ ]]; then MODE=print; else MODE=apply; fi
fi
if [[ "$DEFAULT_ON" == preserve ]]; then
    DEFAULT_ON=off
    if [[ -f "$PROFILE_FILE" ]] && awk '
        /^# --- PROXY-START ---/ {inside=1;next}
        /^# --- PROXY-END ---$/ {inside=0}
        inside && (/^proxy$/ || /^export http_proxy=/) {found=1}
        END {exit !found}
    ' "$PROFILE_FILE"; then DEFAULT_ON=on; fi
fi
render_proxy() {
    echo '# --- PROXY-START --- Managed by setup_proxy_config.sh'
    echo 'proxy() {'
    printf '    export http_proxy=%q\n' "$PROXY_URL"
    printf '    export https_proxy=%q\n' "$PROXY_URL"
    printf '    export all_proxy=%q\n' "${SOCKS_URL:-$PROXY_URL}"
    echo '    export no_proxy="${no_proxy:-localhost,127.0.0.1,::1,.local}"'
    echo '}'
    echo 'unproxy() { unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; }'
    [[ "$DEFAULT_ON" != on ]] || echo proxy
    echo '# --- PROXY-END ---'
}
if [[ "$MODE" == print ]]; then render_proxy; exit 0; fi
[[ -d "$(dirname "$PROFILE_FILE")" ]] || { echo '目标目录不存在' >&2; exit 2; }
trap 'lc_tx_unlock' EXIT
lc_tx_begin "$PROFILE_FILE"
lc_remove_block_candidate "$LC_TX_CANDIDATE" '# --- PROXY-START --- Managed by setup_proxy_config.sh' '# --- PROXY-END ---'
# Complete the final user line, without accumulating blank lines on reruns.
if [[ -s "$LC_TX_CANDIDATE" && -n "$(tail -c 1 "$LC_TX_CANDIDATE")" ]]; then printf '\n' >> "$LC_TX_CANDIDATE"; fi
render_proxy >> "$LC_TX_CANDIDATE"
if [[ "$PROFILE_FILE" == *.zshrc ]]; then zsh -n "$LC_TX_CANDIDATE"; else bash -n "$LC_TX_CANDIDATE"; fi
lc_tx_commit
echo '代理配置已提交；新 Shell 读取后生效。未声明的 SOCKS 能力不会自动添加。'
