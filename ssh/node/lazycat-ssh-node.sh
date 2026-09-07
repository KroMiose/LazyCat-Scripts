#!/usr/bin/env bash
#
# ==============================================================================
# 脚本名称: lazycat-ssh-node.sh (Node)
# 功    能: 被访问设备侧启用 SSH CA：写入 CA 公钥、幂等修改 sshd_config，
#           并使配置生效。提供移除功能。
# 适用系统: Linux / macOS（需 root）
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

CA_PUB_PATH_DEFAULT="/etc/ssh/lazycat_ca.pub"
CA_PUB_PATH="${LAZYCAT_SSH_CA_PUB_PATH:-$CA_PUB_PATH_DEFAULT}"

SSHD_CONFIG_DEFAULT="/etc/ssh/sshd_config"
SSHD_CONFIG="${LAZYCAT_SSHD_CONFIG_PATH:-$SSHD_CONFIG_DEFAULT}"

lc_require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    lc_die "此脚本需要 root 权限，请使用 sudo 运行。"
  fi
}

lc_is_macos() {
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]
}

lc_is_openwrt() {
  [[ -f /etc/openwrt_release ]]
}

lc_preflight() {
  if [[ ! -f "$SSHD_CONFIG" ]] || ! command -v sshd >/dev/null 2>&1; then
    if lc_is_openwrt; then
      lc_die "当前节点尚未配置 OpenSSH。请使用 install-openwrt <CA公钥> <内网IPv4> [端口，默认2222]；Dropbear 无法使用此 CA 配置。"
    fi
    lc_die "需要已安装的 OpenSSH 服务及配置文件：$SSHD_CONFIG"
  fi
  command -v ssh-keygen >/dev/null 2>&1 || lc_die "缺少 ssh-keygen，无法校验 CA 公钥。"
}

lc_validate_ca() {
  local key="$1" tmp
  [[ "$key" != *$'\n'* && "$key" != *'-cert-v01@openssh.com'* ]] || return 1
  tmp="$(mktemp)" || return 1
  printf '%s\n' "$key" > "$tmp"
  ssh-keygen -l -f "$tmp" >/dev/null 2>&1
  local result=$?
  rm -f "$tmp"
  return "$result"
}

lc_openwrt_apply_service() {
  local was_running="$1"
  if [[ "$was_running" == 1 ]]; then
    lc_openwrt_service reload || return 1
  else
    lc_openwrt_service start || return 1
  fi
  # procd starts asynchronously; poll condition within a bounded deadline.
  local deadline=$((SECONDS + 15))
  until lc_openwrt_service running; do
    (( SECONDS < deadline )) || return 1
    sleep 1
  done
}

lc_openwrt_service() {
  /etc/init.d/sshd "$@"
}

lc_install_openwrt() {
  local key="${1:-}" address="${2:-}" port="${3:-2222}"
  lc_is_openwrt || lc_die "install-openwrt 仅适用于 OpenWrt / ImmortalWrt。"
  [[ "$SSHD_CONFIG" == /etc/ssh/sshd_config && "$CA_PUB_PATH" == /etc/ssh/lazycat_ca.pub ]] || lc_die "OpenWrt 安装不支持覆盖配置路径。"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port > 0 && 10#$port <= 65535 && 10#$port != 22 )) || lc_die "端口必须为 1–65535，且不能使用 Dropbear 的 22 端口。"
  port=$((10#$port))
  [[ "$address" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)[0-9.]+$ ]] || lc_die "必须指定本机 RFC1918 内网 IPv4 地址。"
  ip -4 addr show | awk -v ip="$address" '$1 == "inet" { split($2,a,"/"); if (a[1] == ip) found=1 } END { exit !found }' || lc_die "内网地址未配置在本机：$address"
  local was_running=0 enabled=0
  if [[ -x /etc/init.d/sshd ]]; then
    /etc/init.d/sshd running && was_running=1
    /etc/init.d/sshd enabled && enabled=1
  fi
  if [[ "$was_running" == 1 ]] && ! grep -q '^# LazyCat managed OpenWrt listener$' "$SSHD_CONFIG"; then
    lc_die "已有运行中的 OpenSSH；请先检查现有监听和配置，安装流程不会覆盖该服务。"
  fi
  command -v netstat >/dev/null 2>&1 || lc_die "缺少 netstat，无法检查端口占用。"
  if netstat -lnt | awk -v port="$port" '$1 ~ /^tcp/ && $4 ~ (":" port "$") { found=1 } END { exit !found }'; then
    [[ "$was_running" == 1 ]] && grep -qx "Port $port" "$SSHD_CONFIG" && grep -qx "ListenAddress $address" "$SSHD_CONFIG" || lc_die "端口已被占用：$port"
  fi
  command -v opkg >/dev/null 2>&1 || lc_die "此安装入口需要 opkg。"
  local available
  available="$(df -Pk /etc | awk 'END { print $4 }')"
  [[ "$available" =~ ^[0-9]+$ ]] && (( available >= 16384 )) || lc_die "可写空间不足 16 MiB，请先检查存储。"
  if ! command -v sshd >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; then
    opkg update || lc_die "更新软件源失败；Dropbear 保持原状。"
    local install_result=0
    opkg install openssh-server openssh-keygen || install_result=$?
    # Even a partially completed package install can enable the default service.
    if [[ "$was_running" == 0 && -x /etc/init.d/sshd ]]; then
      /etc/init.d/sshd stop
      [[ "$enabled" == 1 ]] || /etc/init.d/sshd disable
    fi
    [[ "$install_result" == 0 ]] || lc_die "安装 OpenSSH 失败；Dropbear 保持原状。"
  fi
  lc_preflight
  lc_validate_ca "$key" || lc_die "无效的 CA 公钥。"
  [[ -x /etc/init.d/sshd ]] || lc_die "未找到 OpenWrt sshd 服务。"
  # Package installation may enable the service before it has our configuration.
  if [[ "$was_running" == 0 ]]; then
    /etc/init.d/sshd stop
    [[ "$enabled" == 1 ]] || /etc/init.d/sshd disable
  fi
  ssh-keygen -A || lc_die "生成主机密钥失败。"
  mkdir -p /var/empty
  chmod 700 /var/empty
  local backup
  backup="$(mktemp -d /etc/ssh/lazycat-backup.XXXXXX)"
  cp -p "$SSHD_CONFIG" "$backup/sshd_config"
  [[ ! -f "$CA_PUB_PATH" ]] || cp -p "$CA_PUB_PATH" "$backup/ca.pub"
  local result
  set +e
  (
    set -e
    printf '%s\n' "$key" > "$CA_PUB_PATH"
    chmod 644 "$CA_PUB_PATH"
    printf '%s\n' '# LazyCat managed OpenWrt listener' "Port $port" "ListenAddress $address" \
      'HostKey /etc/ssh/ssh_host_ed25519_key' 'PubkeyAuthentication yes' \
      "$LC_MARK_BEGIN_SSHD_CONFIG" "TrustedUserCAKeys $CA_PUB_PATH" "$LC_MARK_END_SSHD_CONFIG" \
      'PermitRootLogin prohibit-password' 'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' 'AuthorizedKeysFile none' > "$SSHD_CONFIG"
    chmod 600 "$SSHD_CONFIG"
    sshd -t -f "$SSHD_CONFIG"
    lc_openwrt_apply_service "$was_running"
    netstat -lnt | awk -v endpoint="$address:$port" '$1 ~ /^tcp/ && $4 == endpoint { found=1 } END { exit !found }'
    /etc/init.d/sshd enable
  )
  result=$?
  set -e
  if [[ "$result" != 0 ]]; then
    cp -p "$backup/sshd_config" "$SSHD_CONFIG"
    if [[ -f "$backup/ca.pub" ]]; then cp -p "$backup/ca.pub" "$CA_PUB_PATH"; else rm -f "$CA_PUB_PATH"; fi
    if [[ "$was_running" == 1 ]]; then /etc/init.d/sshd reload || true; else /etc/init.d/sshd stop || true; fi
    if [[ "$enabled" == 1 ]]; then /etc/init.d/sshd enable || true; else /etc/init.d/sshd disable || true; fi
    lc_die "OpenSSH 配置或启动失败，已尝试恢复原配置及服务状态。备份：$backup；Dropbear 未修改。"
  fi
  lc_log "OpenSSH 已启动于 $address:$port，Dropbear 保持原状。备份：$backup"
  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
  lc_log "请从客户端验证证书登录后再修改 Gist 的 lan_port。"
}

lc_reload_sshd() {
  if lc_is_openwrt; then
    [[ -x /etc/init.d/sshd ]] || lc_die "未找到 /etc/init.d/sshd。"
    local running=0
    /etc/init.d/sshd running && running=1
    lc_openwrt_apply_service "$running" || lc_die "OpenWrt sshd 启动或 reload 失败。"
    return 0
  fi
  if lc_is_macos; then
    lc_log "⏳ 检查 macOS launchd 中的 sshd..."
    if ! command -v launchctl >/dev/null 2>&1; then
      lc_die "当前系统为 macOS，但未找到 launchctl。请检查系统环境。"
    fi

    if launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
      lc_log "✅ sshd 已由 launchd 注册；macOS 会为新连接自动读取最新配置，无需 reload。"
    else
      lc_err "⚠️ 未检测到 launchd 服务 com.openssh.sshd；配置已写入，将在启用“远程登录”后生效。"
    fi
    return 0
  fi

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

  if [[ $ok -ne 1 ]] && command -v systemctl >/dev/null 2>&1; then
    # Ubuntu socket activation can leave ssh.service inactive after an upgrade.
    # Start only a service whose SSH socket is already active; do not enable a
    # previously disabled SSH endpoint or restart existing management sessions.
    if systemctl is-active --quiet ssh.socket; then
      systemctl start ssh.service || lc_die "SSH socket 已启用，但启动 ssh.service 失败。"
      systemctl is-active --quiet ssh.service || lc_die "ssh.service 未进入 active。"
      ok=1
    fi
  fi
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

  local key
  key="$(cat "$tmp")"
  rm -f "$tmp"
  trap - RETURN
  lc_install_with_arg "$key"
}

lc_node_transaction() (
  set -e
  action="$1";key="${2:-}";work="";lock="";applied_ca=0;applied_config=0;complete=0
  lc_preflight
  [[ ! -L "$SSHD_CONFIG" && ! -L "$CA_PUB_PATH" ]] || lc_die '配置或 CA 是符号链接，需要人工采纳。'
  [[ "$CA_PUB_PATH" != *$'\n'* && "$CA_PUB_PATH" != *$'\r'* && "$CA_PUB_PATH" != *'"'* && "$CA_PUB_PATH" != *'\'* ]] || lc_die 'CA 路径需要人工审阅。'
  if [[ "$action" == install ]]; then lc_validate_ca "$key" || lc_die '无效的 CA 公钥。'; fi
  lock="${SSHD_CONFIG}.lazycat-lock"
  mkdir "$lock" || lc_die "节点操作锁已存在：$lock"
  work=$(mktemp -d "$(dirname "$SSHD_CONFIG")/lazycat-backup.XXXXXX")
  chmod 700 "$work"
  cp -p "$SSHD_CONFIG" "$work/sshd_config"
  cp -p "$SSHD_CONFIG" "$work/config.after"
  [[ ! -f "$CA_PUB_PATH" ]] || cp -p "$CA_PUB_PATH" "$work/ca.pub"
  printf 'prepared\n' > "$work/status"
  lc_node_finish() {
    local result=$? recovery=0
    trap - EXIT
    if [[ "$complete" == 0 && ( "$applied_ca" == 1 || "$applied_config" == 1 ) ]]; then
      if [[ "$applied_config" == 1 ]]; then
        if cmp -s "$SSHD_CONFIG" "$work/config.after" && [[ ! -L "$SSHD_CONFIG" ]]; then
          cp -p "$work/sshd_config" "$work/config.restore"
          mv "$work/config.restore" "$SSHD_CONFIG" || recovery=1
        else recovery=1; fi
      fi
      if [[ "$applied_ca" == 1 ]]; then
        if cmp -s "$CA_PUB_PATH" "$work/ca.after" && [[ ! -L "$CA_PUB_PATH" ]]; then
          if [[ -f "$work/ca.pub" ]]; then
            cp -p "$work/ca.pub" "$work/ca.restore"
            mv "$work/ca.restore" "$CA_PUB_PATH" || recovery=1
          else rm "$CA_PUB_PATH" || recovery=1; fi
        else recovery=1; fi
      fi
      (lc_reload_sshd) || recovery=1
      if [[ "$recovery" == 0 ]]; then printf 'rolled-back\n' > "$work/status";else printf 'rollback-required\n' > "$work/status";fi
      lc_err "节点操作失败，恢复结果见：$work"
    fi
    rmdir "$lock" || true
    exit "$result"
  }
  trap lc_node_finish EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  lc_remove_marked_block "$work/config.after" "$LC_MARK_BEGIN_SSHD_CONFIG" "$LC_MARK_END_SSHD_CONFIG"
  if [[ "$action" == install ]]; then
    cp -p "$work/config.after" "$work/remainder"
    printf '%s\n' "$LC_MARK_BEGIN_SSHD_CONFIG" "TrustedUserCAKeys \"$CA_PUB_PATH\"" "$LC_MARK_END_SSHD_CONFIG" > "$work/config.after"
    cat "$work/remainder" >> "$work/config.after"
    if [[ -f "$work/ca.pub" ]]; then cp -p "$work/ca.pub" "$work/ca.after";fi
    printf '%s\n' "$key" > "$work/ca.after"
    chmod 644 "$work/ca.after"
    sshd -t -f "$work/config.after" -o "TrustedUserCAKeys=\"$work/ca.after\""
  else
    sshd -t -f "$work/config.after"
  fi
  if cmp -s "$SSHD_CONFIG" "$work/config.after" && { [[ "$action" != install ]] || cmp -s "$CA_PUB_PATH" "$work/ca.after"; }; then
    complete=1
    rm -rf "$work"
    lc_log '配置与 CA 无变化，不 reload，不生成备份。'
    exit 0
  fi
  cmp -s "$SSHD_CONFIG" "$work/sshd_config" || lc_die '检测到配置并发修改，未提交。'
  if [[ -f "$work/ca.pub" ]]; then cmp -s "$CA_PUB_PATH" "$work/ca.pub" || lc_die 'CA 被并发修改。';else [[ ! -e "$CA_PUB_PATH" ]] || lc_die 'CA 被并发创建。';fi
  if [[ "$action" == install ]] && ! cmp -s "$CA_PUB_PATH" "$work/ca.after"; then
    local ca_stage
    ca_stage=$(mktemp "${CA_PUB_PATH}.stage.XXXXXX")
    cp -p "$work/ca.after" "$ca_stage"
    mv "$ca_stage" "$CA_PUB_PATH"
    applied_ca=1
  fi
  cp -p "$work/config.after" "$work/config.stage"
  mv "$work/config.stage" "$SSHD_CONFIG"
  applied_config=1
  lc_reload_sshd
  sshd -t -f "$SSHD_CONFIG"
  printf 'committed\n' > "$work/status"
  complete=1
  lc_log "节点配置已生效。操作记录与备份：$work"
)

lc_install_with_arg() {
  lc_node_transaction install "$1"
}

lc_remove_config() {
  if ! lc_confirm "将撤销 LazyCat CA 信任并 reload，保留 CA 公钥与其他配置，确认？" "N"; then return 0;fi
  lc_node_transaction remove
}

lc_show_status() {
  lc_log ""
  lc_log "状态检查："
  lc_log "  - CA 公钥: ${CA_PUB_PATH} $( [[ -f "$CA_PUB_PATH" ]] && echo '(存在)' || echo '(不存在)' )"
  lc_log "  - sshd_config: ${SSHD_CONFIG} $( [[ -f "$SSHD_CONFIG" ]] && echo '(存在)' || echo '(不存在)' )"
  lc_log ""

  if lc_is_openwrt; then
    if [[ -x /etc/init.d/sshd ]]; then /etc/init.d/sshd status || true; fi
    if [[ -x /etc/init.d/dropbear ]]; then /etc/init.d/dropbear status || true; fi
    return 0
  fi

  if lc_is_macos; then
    if ! command -v launchctl >/dev/null 2>&1; then
      lc_err "⚠️ 当前系统为 macOS，但未找到 launchctl。"
      return 0
    fi

    if launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
      lc_log "✅ sshd 已由 launchd 注册（按需启动）。"
    else
      lc_err "⚠️ 未检测到 launchd 服务 com.openssh.sshd，请检查“系统设置 → 通用 → 共享 → 远程登录”。"
    fi
    return 0
  fi

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
    lc_log "  1) 初始化 / 更新（写入 CA 公钥 + 配置并应用 sshd_config）"
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
  if [[ "${1:-}" == install-openwrt ]]; then
    shift
    [[ $# == 2 || $# == 3 ]] || lc_die "用法：install-openwrt <CA公钥> <内网IPv4> [端口]"
    lc_install_openwrt "$@"
    return
  fi
  
  # 如果第一个参数看起来像 SSH 公钥，则自动执行
  if [[ -n "${1:-}" ]] && [[ "$1" == ssh-* ]]; then
     lc_install_with_arg "$1"
     exit 0
  fi

  main_menu
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
  main "$@"
fi
