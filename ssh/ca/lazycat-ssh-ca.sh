#!/usr/bin/env bash
#
# ==============================================================================
# 脚本名称: lazycat-ssh-ca.sh (CA)
# 功    能: SSH CA 离线管理端：初始化 CA、签发 SSH 用户证书。
# 适用系统: Linux & macOS（Bash >= 4）
# 安全提示: 建议在可信环境运行（会在本机生成并保存 CA 私钥）。
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

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
  elif [[ -f "${XDG_DATA_HOME:-$HOME/.local/share}/lazycat-ssh/lib/common.sh" ]]; then
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

  read -r -p "CA 存放目录（默认: ${DEFAULT_CA_DIR}）: " input_dir
  ca_dir="${input_dir:-$DEFAULT_CA_DIR}"

  read -r -p "CA 标识名（默认: ${DEFAULT_CA_NAME}）: " input_name
  ca_name="${input_name:-$DEFAULT_CA_NAME}"

  mkdir -p "$ca_dir"
  chmod 700 "$ca_dir"

  local priv pub
  priv="$(ca_priv_path)"
  pub="$(ca_pub_path)"

  if [[ -f "$priv" ]]; then
    lc_die "CA 私钥已存在：${priv}"
  fi

  lc_log "⏳ 正在生成 ed25519 CA 密钥..."
  ssh-keygen -t ed25519 -f "$priv" -N "" -C "$ca_name"
  chmod 600 "$priv"
  chmod 644 "$pub"

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
    lc_log "⚠️ 未在预期路径找到证书（请检查 ssh-keygen 输出）。"
  fi
}

lc_show_node_setup_hint() {
  if ! lc_ca_exists; then
    lc_die "尚未初始化 CA。"
  fi

  lc_log ""
  lc_log "Node 端配置提示："
  lc_log "1) 在被访问设备上执行："
  lc_log "   sudo bash -c \"$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/node/lazycat-ssh-node.sh)\""
  lc_log "2) 选择“初始化/更新”，按提示粘贴下面的 CA 公钥："
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
  main_menu
}

main "$@"

