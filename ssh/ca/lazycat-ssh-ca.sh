#!/usr/bin/env bash
#
# ==============================================================================
# 脚本名称: lazycat-ssh-ca.sh (CA)
# 功    能: SSH CA 离线管理端：初始化 CA、签发 SSH 用户证书。
# 适用系统: Linux & macOS（Bash >= 3.2）
# 安全提示: 建议在可信环境运行（会在本机生成并保存 CA 私钥）。
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

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

__lc_bootstrap_die() {
  printf '❌ %s\n' "$*" >&2
  exit 1
}

REMOTE_BASE_URL="${LAZYCAT_SSH_REMOTE_BASE_URL:-https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh}"
REMOTE_LIB_URL="${REMOTE_BASE_URL}/lib/common.sh"

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || true
fi

__lc_source_common() {
  local common_lib=""
  if [[ -n "$SCRIPT_DIR" ]] && [[ -f "${SCRIPT_DIR}/../lib/common.sh" ]]; then
    common_lib="${SCRIPT_DIR}/../lib/common.sh"
  elif [[ "$EUID" -ne 0 && -f "${XDG_DATA_HOME:-$HOME/.local/share}/lazycat-ssh/lib/common.sh" ]]; then
    common_lib="${XDG_DATA_HOME:-$HOME/.local/share}/lazycat-ssh/lib/common.sh"
  fi

  if [[ -n "$common_lib" ]]; then
    # shellcheck source=/dev/null
    source "$common_lib"
    return 0
  fi

  # 允许 curl|bash：临时下载 common.sh
  if ! command -v curl >/dev/null 2>&1; then
    __lc_bootstrap_die "无法找到 common.sh，且系统未安装 curl。请先安装 curl 后重试。"
  fi

  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f \"$tmp\"" EXIT

  curl -fsSL "$REMOTE_LIB_URL" -o "$tmp" || __lc_bootstrap_die "下载 common.sh 失败：${REMOTE_LIB_URL}"
  # shellcheck source=/dev/null
  source "$tmp"
  rm -f "$tmp"
  trap - EXIT
}

__lc_source_common

DEFAULT_CA_DIR="$HOME/.lazycat/ssh-ca"
DEFAULT_CA_NAME="lazycat-ssh-ca"

ca_dir="$DEFAULT_CA_DIR"
ca_name="$DEFAULT_CA_NAME"

CA_LOCATION="$HOME/.lazycat/ssh-ca-location"
if [[ -L "$CA_LOCATION" ]]; then lc_die 'CA 位置记录是符号链接，需要人工检查'; fi
if [[ -f "$CA_LOCATION" ]]; then
  { IFS= read -r ca_dir; IFS= read -r ca_name; } < "$CA_LOCATION"
  [[ "$ca_dir" == /* && "$ca_name" =~ ^[A-Za-z0-9._-]+$ && "$ca_name" != . && "$ca_name" != .. ]] || lc_die 'CA 位置记录无效'
fi
DEFAULT_CA_DIR="$ca_dir"
DEFAULT_CA_NAME="$ca_name"

persist_ca_location() (
  set -e
  mkdir -p "$(dirname "$CA_LOCATION")"
  trap lc_tx_unlock EXIT
  lc_tx_begin "$CA_LOCATION"
  printf '%s\n%s\n' "$ca_dir" "$ca_name" > "$LC_TX_CANDIDATE"
  lc_tx_commit
)

ca_priv_path() { printf '%s/%s' "$ca_dir" "${ca_name}"; }
ca_pub_path() { printf '%s/%s.pub' "$ca_dir" "${ca_name}"; }

lc_require_cmds() {
  lc_need_cmd ssh-keygen
}

lc_ca_exists() {
  [[ -f "$(ca_priv_path)" ]] && [[ -f "$(ca_pub_path)" ]]
}

lc_init_ca() {
  lc_require_cmds

  if [[ $# -eq 2 ]]; then
    input_dir="$1"; input_name="$2"
  else
  read -r -p "CA 存放目录（默认: ${DEFAULT_CA_DIR}）: " input_dir
  ca_dir="${input_dir:-$DEFAULT_CA_DIR}"

  read -r -p "CA 标识名（默认: ${DEFAULT_CA_NAME}）: " input_name
  fi
  ca_dir="${input_dir:-$DEFAULT_CA_DIR}"
  ca_name="${input_name:-$DEFAULT_CA_NAME}"
  [[ "$ca_dir" == /* && "$ca_dir" != *$'\n'* && "$ca_dir" != *$'\r'* ]] || lc_die 'CA 目录必须为绝对单行路径'
  [[ "$ca_name" =~ ^[A-Za-z0-9._-]+$ && "$ca_name" != . && "$ca_name" != .. ]] || lc_die 'CA 名称无效'

  lc_tx_check_path "$ca_dir" || lc_die 'CA 目录包含符号链接，需要人工采纳'
  if [[ ! -d "$ca_dir" ]]; then (umask 077; mkdir -p "$ca_dir"); fi

  local priv pub
  priv="$(ca_priv_path)"
  pub="$(ca_pub_path)"

  if [[ -e "$priv" || -L "$priv" || -e "$pub" || -L "$pub" ]]; then
    lc_die "CA 私钥已存在：${priv}"
  fi

  lc_need_cmd link
  local staging
  staging=$(mktemp -d "$ca_dir/.lazycat-ca-init.XXXXXX")
  chmod 700 "$staging"
  printf 'prepared\n' > "$staging/status"
  lc_log "⏳ 正在生成 ed25519 CA 密钥..."
  (umask 077; ssh-keygen -t ed25519 -f "$staging/key" -N "" -C "$ca_name")
  chmod 600 "$staging/key"
  chmod 644 "$staging/key.pub"
  # link invokes the exclusive filesystem operation directly: unlike ln it
  # never treats a newly appeared directory as permission to create inside it.
  # On interruption retain the private staging directory for explicit recovery.
  lc_tx_check_path "$ca_dir" || lc_die "路径已变化，候选密钥保存在：$staging"
  link "$staging/key" "$priv" || lc_die "私钥目标被并发创建；未覆盖。候选保存在：$staging"
  printf 'private-published\n' > "$staging/status"
  link "$staging/key.pub" "$pub" || lc_die "公钥目标被并发创建；未覆盖。请检查已发布私钥及候选：$staging"
  printf 'pair-published\n' > "$staging/status"
  persist_ca_location
  rm -rf "$staging"

  lc_log "✅ CA 初始化完成："
  lc_log "  - 私钥: ${priv}"
  lc_log "  - 公钥: ${pub}"
}

lc_show_ca_pub() {
  if ! lc_ca_exists; then
    lc_die "尚未初始化 CA。"
  fi
  cat "$(ca_pub_path)"
}

lc_sign_pubkey() {
  lc_require_cmds
  if ! lc_ca_exists; then
    lc_die "尚未初始化 CA。"
  fi

  local pubkey_path=""
  read -r -p "待签发的 SSH 公钥路径（.pub）: " pubkey_path
  [[ -f "$pubkey_path" ]] || lc_die "未找到公钥文件：${pubkey_path}"

  local identity=""
  read -r -p "证书 identity（默认: $(hostname -s)）: " identity
  identity="${identity:-$(hostname -s)}"

  local validity=""
  read -r -p "有效期（默认: 12h，例如 12h/7d）: " validity
  validity="${validity:-12h}"

  local principals=""
  read -r -p "允许登录用户 principals（默认: root，可逗号分隔）: " principals
  principals="${principals:-root}"

  local out_dir out_cert
  out_dir="$(dirname "$pubkey_path")"
  out_cert="${out_dir}/$(basename "${pubkey_path%.pub}")-cert.pub"

  lc_log "⏳ 正在签发证书..."
  ssh-keygen -s "$(ca_priv_path)" \
    -I "$identity" \
    -n "$principals" \
    -V "+$validity" \
    -z "$(date +%s)" \
    "$pubkey_path"

  # ssh-keygen 输出证书到同目录，命名为 <key>-cert.pub
  if [[ -f "$out_cert" ]]; then
    lc_log "✅ 证书已生成：${out_cert}"
  else
    lc_die "未在预期路径找到证书（请检查 ssh-keygen 输出）。"
  fi
}

lc_show_node_setup_hint() {
  if ! lc_ca_exists; then
    lc_die "尚未初始化 CA。"
  fi

  lc_log ""
  lc_log "Node 端配置提示："
  lc_log "1) 在被访问设备上执行："
  cat <<'DOWNLOAD'
(
  set -e
  script=$(mktemp)
  trap 'rm -f "$script"' EXIT
  curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/node/lazycat-ssh-node.sh -o "$script"
DOWNLOAD
  printf '  sudo bash "$script" %q\n' "$(cat "$(ca_pub_path)")"
  printf ')\n'
  lc_log "2) 如果已使用第一种方式（带参数），则自动完成配置。"
  lc_log "   否则运行后选择“初始化/更新”，按提示粘贴下面的 CA 公钥："
  lc_log ""
  cat "$(ca_pub_path)"
  lc_log ""
}

main_menu() {
  lc_log ""
  lc_log "=== LazyCat SSH CA（管理端）==="
  lc_log ""

  if lc_ca_exists; then
    lc_log "状态：已初始化（${ca_dir}/${ca_name}）"
  else
    lc_log "状态：未初始化"
  fi
  lc_log ""

  while true; do
    if lc_ca_exists; then
      lc_log "  1) 查看 CA 公钥"
      lc_log "  2) 签发 SSH 公钥证书"
      lc_log "  3) 查看 Node 端配置提示"
      lc_log "  4) 退出"
      lc_log ""
      read -r -p "请输入编号: " choice
      lc_log ""
      case "${choice}" in
        1) lc_show_ca_pub ;;
        2) lc_sign_pubkey ;;
        3) lc_show_node_setup_hint ;;
        4) exit 0 ;;
        *) lc_log "无效选项: ${choice}" ;;
      esac
    else
      lc_log "  1) 初始化 CA"
      lc_log "  2) 退出"
      lc_log ""
      read -r -p "请输入编号: " choice
      lc_log ""
      case "${choice}" in
        1) lc_init_ca ;;
        2) exit 0 ;;
        *) lc_log "无效选项: ${choice}" ;;
      esac
    fi
  done
}

main() {
  lc_require_cmds
  case "${1:-}" in
    "") main_menu ;;
    show) [[ $# == 1 ]] || lc_die 'show 不接受参数'; lc_show_ca_pub ;;
    init) [[ $# == 5 && "$2" == --dir && "$4" == --name ]] || lc_die 'init --dir <绝对路径> --name <名称>'; lc_init_ca "$3" "$5" ;;
    *) lc_die '用法：lazycat-ssh-ca.sh [show | init --dir <目录> --name <名称>]' ;;
  esac
}

main "$@"
