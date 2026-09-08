#!/usr/bin/env bash
# Docker drop-in configuration and service restart are explicit separate actions.
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
# Automatic failure recovery may only replace the exact revision we published.
# Missing revision evidence is a conflict, not permission to discard user attrs.
lc_tx_matches_committed() {
    local target="$1" operation="$2"
    [[ -f "$target" && ! -L "$target" && -f "$operation/after" && ! -L "$operation/after" &&
       -f "$operation/committed-revision" && ! -L "$operation/committed-revision" ]] || return 3
    [[ "$(lc_tx_revision "$target")" == "$(cat "$operation/committed-revision")" ]] &&
        cmp -s "$target" "$operation/after" || return 3
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
    # Bash $$ identifies the original shell even inside a live subshell.
    # exec makes the helper's parent the actual caller, including Bash 3.2.
    LC_TX_OWNER_PID=$(exec /bin/sh -c 'printf "%s\n" "$PPID"')
    [[ "$LC_TX_OWNER_PID" =~ ^[1-9][0-9]*$ ]] || return 3
    printf '%s\n' "$LC_TX_OWNER_PID" > "$LC_TX_LOCK/pid"
    printf 'actual-shell-v1\n' > "$LC_TX_LOCK/pid-format"
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
    [[ -f "$lock/pid-format" && ! -L "$lock/pid-format" && "$(cat "$lock/pid-format")" == actual-shell-v1 ]] || { echo '旧锁没有实际持锁进程证据，需人工检查，未移动' >&2; return 3; }
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
    [[ ! -L "$LC_TX_LOCK" && -f "$LC_TX_LOCK/pid" && ! -L "$LC_TX_LOCK/pid" &&
       "$(cat "$LC_TX_LOCK/pid")" == "${LC_TX_OWNER_PID:-}" &&
       "$(exec /bin/sh -c 'printf "%s\n" "$PPID"')" == "${LC_TX_OWNER_PID:-}" ]] || { echo '锁归属变化，未释放' >&2; return 3; }
    rm -f "$LC_TX_LOCK/pid" "$LC_TX_LOCK/pid-format"
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
    # A later metadata-only edit must also prevent destructive rollback. Record
    # the published inode, not the candidate inode which rename may replace.
    lc_tx_revision "$LC_TX_TARGET" > "$LC_TX_OPERATION/committed-revision" || return 1
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
[[ "$EUID" == 0 && -d /run/systemd/system ]] || { echo '需要 root 和真实 systemd' >&2; exit 2; }
command -v docker >/dev/null || { echo 'Docker 尚未安装' >&2; exit 1; }
target=/etc/systemd/system/docker.service.d/http-proxy.conf
mode="${1:-menu}"
[[ $# == 0 ]] || shift
url=''
no_proxy_value=localhost,127.0.0.1,::1
restart=0
adopt=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url|--no-proxy) [[ $# -ge 2 ]] || exit 2; if [[ "$1" == --url ]]; then url="$2"; else no_proxy_value="$2"; fi; shift 2 ;;
        --restart) restart=1;shift ;;
        --adopt) adopt=1;shift ;;
        *) echo '参数无效' >&2;exit 2 ;;
    esac
done
if [[ "$mode" == menu ]]; then
    read -r -p '1 配置代理 / 2 移除托管代理 / 3 退出: ' choice
    case "$choice" in 1) mode=set;read -r -p '完整 HTTP(S) 代理 URL: ' url ;; 2) mode=remove ;; *) exit 0 ;; esac
fi
if [[ "$mode" == check ]]; then
    if [[ -e "$target" ]]; then echo "配置文件存在：$target（不输出认证内容）"; else echo '未发现此代理片段'; fi
    systemctl is-active docker
    exit
fi
case "$mode" in set|remove) ;; *) echo '用法：set --url URL [--no-proxy LIST] [--restart] [--adopt] | remove [--restart] | check' >&2;exit 2 ;; esac
if [[ "$mode" == set ]]; then
    case "$url" in http://*|https://*) ;; *) echo 'Docker 代理需要 HTTP(S) URL' >&2;exit 2 ;; esac
    [[ "$url" != *[[:space:]]* && "$url" != *['"\`']* && "$no_proxy_value" != *[[:space:]]* && "$no_proxy_value" != *['"\`']* ]] || { echo '配置包含非法控制或引号字符' >&2;exit 2; }
fi
if [[ -f "$target" && "$adopt" != 1 ]] && ! grep -qx '# Managed by LazyCat Docker proxy' "$target"; then
    echo '既有片段归属未确认；检查后使用 --adopt 明确采纳，原文件未修改。' >&2;exit 3
fi
[[ ! -L "$(dirname "$target")" ]] || exit 3
if [[ ! -d "$(dirname "$target")" ]]; then mkdir -p "$(dirname "$target")"; fi
trap 'lc_tx_unlock' EXIT
lc_tx_begin "$target"
if [[ "$mode" == set ]]; then
    # systemd expands % specifiers even inside quotes; URL escapes need %%.
    url=${url//%/%%};no_proxy_value=${no_proxy_value//%/%%}
    printf '# Managed by LazyCat Docker proxy\n[Service]\nEnvironment="HTTP_PROXY=%s"\nEnvironment="HTTPS_PROXY=%s"\nEnvironment="NO_PROXY=%s"\n' "$url" "$url" "$no_proxy_value" > "$LC_TX_CANDIDATE"
else
    # A commented empty owned fragment stops contributing proxy variables;
    # other Docker fragments and daemon.json remain untouched.
    printf '# Managed by LazyCat Docker proxy\n# Proxy settings removed\n' > "$LC_TX_CANDIDATE"
fi
was_active=0
systemctl is-active --quiet docker && was_active=1
lc_tx_commit
[[ "$restart" == 1 ]] || { echo '配置已保存，待应用；Docker 未重启。维护窗口执行 daemon-reload 和 restart。';exit 0; }
if systemctl daemon-reload && systemctl restart docker && systemctl is-active --quiet docker; then
    echo 'Docker 已按显式请求重启；请验证实际拉取行为。'
    exit 0
fi
# A restart can affect containers; only config/service state is recoverable here.
if [[ -d "$LC_TX_OPERATION" ]]; then
    lc_tx_matches_committed "$target" "$LC_TX_OPERATION" || {
        printf 'recovery-conflict\n' > "$LC_TX_OPERATION/status"
        echo 'Docker 应用失败后配置或属性已变化，保留现场，不继续恢复文件或切换服务。' >&2
        exit 3
    }
    if [[ "$LC_TX_EXISTED" == 1 ]]; then
        lc_tx_copy "$LC_TX_OPERATION/before" "$LC_TX_OPERATION/restore"
        lc_tx_matches_committed "$target" "$LC_TX_OPERATION" || { printf 'recovery-conflict\n' > "$LC_TX_OPERATION/status"; exit 3; }
        mv "$LC_TX_OPERATION/restore" "$target"
    else rm "$target"; fi
    printf 'rollback-attempted\n' > "$LC_TX_OPERATION/status"
    systemctl daemon-reload || echo '恢复后的 daemon-reload 失败' >&2
    if [[ "$was_active" == 1 ]]; then systemctl restart docker || echo '旧配置服务恢复失败' >&2; else systemctl stop docker || echo '服务停止失败' >&2; fi
fi
echo 'Docker 应用失败；请查看操作记录和 journalctl，不能把容器业务状态视为已回滚。' >&2
exit 1
