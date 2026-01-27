#!/usr/bin/env bash
#
# ==============================================================================
# 脚本名称: lazycat-ssh-node.sh (Node)
# 功    能: 被访问设备侧启用 SSH CA：写入 CA 公钥、幂等修改 sshd_config，
#           并 reload sshd。提供移除功能。
# 适用系统: Linux（需 root）
# 使用方法: sudo bash -c \"$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/node/lazycat-ssh-node.sh)\"
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

CA_PUB_PATH_DEFAULT="/etc/ssh/lazycat_ca.pub"
CA_PUB_PATH="${LAZYCAT_SSH_CA_PUB_PATH:-$CA_PUB_PATH_DEFAULT}"

SSHD_CONFIG_DEFAULT="/etc/ssh/sshd_config"
SSHD_CONFIG="${LAZYCAT_SSHD_CONFIG_PATH:-$SSHD_CONFIG_DEFAULT}"

lc_require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    lc_die "此脚本需要 root 权限，请使用 sudo 运行。"
  fi
}

lc_reload_sshd() {
  lc_log "⏳ 正在尝试 reload sshd..."
  set +e
  local tried=0
  local ok=0
  local last_out=""

  for cmd in \
    "systemctl reload sshd" \
    "systemctl reload ssh" \
    "service sshd reload" \
    "service ssh reload"; do
    tried=$((tried + 1))
    lc_log "  -> 尝试: ${cmd}"
    last_out="$(bash -c "$cmd" 2>&1)"
    if [[ $? -eq 0 ]]; then
      ok=1
      break
    fi
    lc_err "     失败输出：${last_out}"
  done
  set -e

  if [[ $ok -ne 1 ]]; then
    lc_die "sshd reload 失败（已尝试 ${tried} 种方式）。请手动检查服务管理方式与配置语法。"
  fi

  lc_log "✅ sshd reload 成功。"
}

lc_paste_ca_pubkey() {
  lc_log ""
  lc_log "请粘贴 SSH CA 公钥内容（通常以 'ssh-ed25519' 或 'ssh-rsa' 开头）。"
  lc_log "输入完成后，在新的一行按 Ctrl+D 结束。"
  lc_log ""

  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  cat >"$tmp"
  if [[ ! -s "$tmp" ]]; then
    lc_die "未检测到任何输入，已取消。"
  fi

  # 写入目标路径
  install -m 0644 "$tmp" "$CA_PUB_PATH"
  lc_log "✅ 已写入 CA 公钥: ${CA_PUB_PATH}"
}

lc_apply_sshd_config() {
  [[ -f "$SSHD_CONFIG" ]] || lc_die "未找到 sshd_config: ${SSHD_CONFIG}"

  # 备份（用于回滚）
  local bak="${SSHD_CONFIG}.bak.$(lc_ts)"
  cp "$SSHD_CONFIG" "$bak"
  lc_log "  -> 已创建备份: $bak"
  lc_remove_marked_block "$SSHD_CONFIG" "$LC_MARK_BEGIN_SSHD_CONFIG" "$LC_MARK_END_SSHD_CONFIG"

  local content="TrustedUserCAKeys ${CA_PUB_PATH}"
  lc_append_marked_block "$SSHD_CONFIG" "$LC_MARK_BEGIN_SSHD_CONFIG" "$content" "$LC_MARK_END_SSHD_CONFIG"
  lc_log "✅ 已更新 sshd_config 标记块。"

  # 语法预检查：避免 reload 后把自己锁在门外
  if command -v sshd >/dev/null 2>&1; then
    if ! sshd -t -f "$SSHD_CONFIG" 2>&1; then
      lc_err "❌ sshd_config 语法检查失败，正在回滚到备份：$bak"
      cp "$bak" "$SSHD_CONFIG"
      lc_die "已回滚 sshd_config，请检查配置后重试。"
    fi
  else
    lc_err "⚠️ 未检测到 sshd 命令，跳过 sshd_config 语法检查（仍将尝试 reload）。"
  fi
}

lc_remove_config() {
  if ! lc_confirm "将移除 LazyCat SSH CA 配置并 reload sshd，确认继续？" "N"; then
    lc_die "用户取消。"
  fi

  if [[ -f "$SSHD_CONFIG" ]]; then
    lc_backup_file "$SSHD_CONFIG"
    lc_remove_marked_block "$SSHD_CONFIG" "$LC_MARK_BEGIN_SSHD_CONFIG" "$LC_MARK_END_SSHD_CONFIG"
    lc_log "✅ 已移除 sshd_config 标记块。"
  fi

  if [[ -f "$CA_PUB_PATH" ]]; then
    if lc_confirm "是否同时删除 CA 公钥文件 ${CA_PUB_PATH}？" "N"; then
      rm -f "$CA_PUB_PATH"
      lc_log "✅ 已删除 CA 公钥文件。"
    fi
  fi

  lc_reload_sshd
}

lc_show_status() {
  lc_log ""
  lc_log "状态检查："
  lc_log "  - CA 公钥: ${CA_PUB_PATH} $( [[ -f "$CA_PUB_PATH" ]] && echo '(存在)' || echo '(不存在)' )"
  lc_log "  - sshd_config: ${SSHD_CONFIG} $( [[ -f "$SSHD_CONFIG" ]] && echo '(存在)' || echo '(不存在)' )"
  lc_log ""

  set +e
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --full status sshd
    if [[ $? -ne 0 ]]; then
      lc_err "⚠️ 未能获取 sshd 的 systemctl 状态（可能服务名不同或系统不使用 systemd）。"
    fi
    systemctl --no-pager --full status ssh
    if [[ $? -ne 0 ]]; then
      lc_err "⚠️ 未能获取 ssh 的 systemctl 状态（可能服务名不同）。"
    fi
    set -e
    return 0
  fi

  if command -v service >/dev/null 2>&1; then
    service sshd status
    if [[ $? -ne 0 ]]; then
      lc_err "⚠️ 未能获取 sshd 的 service 状态（可能服务名不同）。"
    fi
    service ssh status
    if [[ $? -ne 0 ]]; then
      lc_err "⚠️ 未能获取 ssh 的 service 状态（可能服务名不同）。"
    fi
    set -e
    return 0
  fi
  set -e

  lc_log "未检测到 systemctl/service，无法展示服务状态。"
}

main_menu() {
  lc_log ""
  lc_log "=== LazyCat SSH Node（被访问设备）==="
  lc_log ""

  while true; do
    lc_log "请选择操作："
    lc_log "  1) 初始化 / 更新（写入 CA 公钥 + 配置 sshd_config + reload）"
    lc_log "  2) 查看当前 CA 公钥"
    lc_log "  3) 移除 LazyCat SSH CA 配置"
    lc_log "  4) 检查 sshd 状态"
    lc_log "  5) 退出"
    lc_log ""
    read -r -p "请输入编号: " choice
    lc_log ""
    case "${choice}" in
      1)
        lc_paste_ca_pubkey
        lc_apply_sshd_config
        lc_reload_sshd
        ;;
      2)
        if [[ -f "$CA_PUB_PATH" ]]; then
          cat "$CA_PUB_PATH"
        else
          lc_log "CA 公钥文件不存在：${CA_PUB_PATH}"
        fi
        ;;
      3) lc_remove_config ;;
      4) lc_show_status ;;
      5) exit 0 ;;
      *) lc_log "无效选项: ${choice}" ;;
    esac
  done
}

main() {
  lc_require_root
  main_menu
}

main "$@"

