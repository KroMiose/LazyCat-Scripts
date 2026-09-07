#!/usr/bin/env bash
# Discover candidate backups without inferring ownership from names; never bulk-delete.
set -euo pipefail
# lazycat-file-transaction:begin
# Single-file candidate/backup protocol. Embedded into standalone release scripts.
# Call lc_tx_begin, edit "$LC_TX_CANDIDATE", validate, then lc_tx_commit.
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
    (umask 077; mkdir "$LC_TX_LOCK") || { echo "操作锁已存在，请检查并发或中断状态：$LC_TX_LOCK" >&2; return 3; }
    LC_TX_LOCK_OWNED=1
    printf '%s\n' "$$" > "$LC_TX_LOCK/pid"
    LC_TX_OPERATION=$(mktemp -d "${LC_TX_TARGET}.lazycat-operation.XXXXXX")
    chmod 700 "$LC_TX_OPERATION"
    printf '%s\n' "$LC_TX_TARGET" > "$LC_TX_OPERATION/target"
    LC_TX_EXISTED=0
    if [[ -e "$LC_TX_TARGET" ]]; then
        [[ -f "$LC_TX_TARGET" ]] || { lc_tx_unlock; echo '目标不是普通文件' >&2; return 3; }
        LC_TX_EXISTED=1
        LC_TX_METADATA=$(LC_ALL=C ls -ldn "$LC_TX_TARGET" | awk '{print $1, $3, $4}')
        printf '%s\n' "$LC_TX_METADATA" > "$LC_TX_OPERATION/metadata"
        cp -p "$LC_TX_TARGET" "$LC_TX_OPERATION/before"
    else
        (umask 077; : > "$LC_TX_OPERATION/before")
    fi
    LC_TX_METADATA=$(LC_ALL=C ls -ldn "$LC_TX_OPERATION/before" | awk '{print $1, $3, $4}')
    printf '%s\n' "$LC_TX_METADATA" > "$LC_TX_OPERATION/metadata"
    printf '%s\n' "$LC_TX_EXISTED" > "$LC_TX_OPERATION/existed"
    cp -p "$LC_TX_OPERATION/before" "$LC_TX_OPERATION/after"
    LC_TX_CANDIDATE="$LC_TX_OPERATION/after"
    printf 'prepared\n' > "$LC_TX_OPERATION/status"
}
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
    cp -p "$LC_TX_CANDIDATE" "$staged"
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
    cp -p "$file" "$tmp"
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { inside=1; next }
        $0 == end { inside=0; next }
        !inside { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}
# lazycat-file-transaction:end
backups=()
targets=()
shopt -s nullglob
for target in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.ssh/config"; do
    for candidate in "$target".bak.* "$target".cleanup.bak.* "$target".lazycat.bak.* "$target".lazycat-operation.*/before; do
        [[ -f "$candidate" && ! -L "$candidate" ]] || continue
        backups+=("$candidate");targets+=("$target")
    done
done
if [[ "${1:-}" == --list ]]; then
    for ((i=0;i<${#backups[@]};i++)); do printf '%s -> %s\n' "${backups[$i]}" "${targets[$i]}"; done
    exit 0
fi
if [[ "${1:-}" == --restore ]]; then
    [[ $# == 4 && "$3" == --target ]] || { echo '--restore <备份绝对路径> --target <目标绝对路径>' >&2; exit 2; }
    backup="$2";target="$4"
    matched=0
    for ((i=0;i<${#backups[@]};i++)); do
        if [[ "${backups[$i]}" == "$backup" && "${targets[$i]}" == "$target" ]]; then matched=1; fi
    done
    [[ "$matched" == 1 ]] || { echo '备份与登记的候选目标不匹配' >&2; exit 3; }
else
    [[ $# == 0 ]] || { echo '用法：--list | --restore <备份> --target <目标>' >&2; exit 2; }
    [[ ${#backups[@]} -gt 0 ]] || { echo '未发现支持的 Shell 备份。节点/服务备份请使用对应工具检查。'; exit 0; }
    echo '以下仅为候选备份，文件名不能证明归属；不会自动清理。'
    for ((i=0;i<${#backups[@]};i++)); do printf '%s) %s -> %s\n' "$((i+1))" "${backups[$i]}" "${targets[$i]}"; done
    read -r -p '选择编号，q 取消: ' choice
    [[ "$choice" != q && -n "$choice" ]] || exit 0
    [[ "$choice" =~ ^[0-9]{1,6}$ ]] && ((10#$choice>0 && 10#$choice<=${#backups[@]})) || exit 2
    i=$((10#$choice-1));backup="${backups[$i]}";target="${targets[$i]}"
    printf '将恢复 %s 到 %s；当前内容会另行备份。\n' "$backup" "$target"
    read -r -p '输入 yes 确认: ' confirm
    [[ "$confirm" == yes ]] || exit 0
fi
trap 'lc_tx_unlock' EXIT
lc_tx_begin "$target"
# Preserve current file metadata; take only content from the selected history.
cat "$backup" > "$LC_TX_CANDIDATE"
case "$target" in *.zshrc) zsh -n "$LC_TX_CANDIDATE" ;; */.ssh/config) ;; *) bash -n "$LC_TX_CANDIDATE" ;; esac
lc_tx_commit
echo '恢复完成；未执行配置内容。撤销本次恢复可使用新操作记录。'
