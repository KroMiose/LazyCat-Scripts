#!/usr/bin/env bash
#
# ==============================================================================
# 脚本名称: lazycat-ssh.sh (Client)
# 功    能: 控制端 SSH 管理入口：通过 Secret Gist（只读）同步标准 YAML，
#           生成并维护 ~/.ssh/config.d/lazycat.conf，同时对 ~/.ssh/config 写入
#           可移除的 Include 标记块。支持多套配置（多 Gist / 同 Gist 多文件）。
# 适用系统: Linux & macOS（Bash >= 4）
# 使用方法: 1) 首次一键执行（安装到 ~/.local/bin/lazycat-ssh）
#              bash -c \"$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/client/lazycat-ssh.sh)\"\n#           2) 之后直接运行：lazycat-ssh
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

__lc_bootstrap_die() {
  printf '❌ %s\n' "$*" >&2
  exit 1
}

# Reject before sourcing adjacent/cache code or making a bootstrap request.
# The client has always required a normal user; the check must protect bootstrap too.
if [[ "$EUID" -eq 0 ]]; then
  __lc_bootstrap_die "请不要使用 sudo 运行控制端脚本（它会修改当前用户的 ~/.ssh）。"
fi

LAZYCAT_SSH_HOME_DEFAULT="${XDG_DATA_HOME:-$HOME/.local/share}/lazycat-ssh"
LAZYCAT_SSH_HOME="${LAZYCAT_SSH_HOME:-$LAZYCAT_SSH_HOME_DEFAULT}"

LAZYCAT_SSH_BIN_DIR_DEFAULT="$HOME/.local/bin"
LAZYCAT_SSH_BIN_DIR="${LAZYCAT_SSH_BIN_DIR:-$LAZYCAT_SSH_BIN_DIR_DEFAULT}"

REMOTE_BASE_URL="${LAZYCAT_SSH_REMOTE_BASE_URL:-https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh}"
REMOTE_CLIENT_URL="${REMOTE_BASE_URL}/client/lazycat-ssh.sh"
REMOTE_LIB_URL="${REMOTE_BASE_URL}/lib/common.sh"

__lc_source_common() {
  local local_candidate=""
  if [[ -n "${BASH_SOURCE[0]-}" ]] && [[ -f "${BASH_SOURCE[0]-}" ]]; then
    local lib_dir
    lib_dir="$(dirname "${BASH_SOURCE[0]-}")/../lib"
    if [[ -d "$lib_dir" ]] && [[ -f "$lib_dir/common.sh" ]]; then
      local_candidate="$(cd "$lib_dir" && pwd)/common.sh"
    fi
  fi

  if [[ -n "$local_candidate" ]] && [[ -f "$local_candidate" ]]; then
    # shellcheck source=/dev/null
    source "$local_candidate"
    return 0
  fi

  if [[ -f "${LAZYCAT_SSH_HOME}/lib/common.sh" ]]; then
    # shellcheck source=/dev/null
    source "${LAZYCAT_SSH_HOME}/lib/common.sh"
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

META_DIR="$HOME/.lazycat/ssh"
META_PATH="${META_DIR}/meta.env"

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
SSH_CONFIG_D="$SSH_DIR/config.d"
LAZYCAT_CONF="${SSH_CONFIG_D}/lazycat.conf"

# 控制端证书身份（用于 SSH CA 自动化）
CA_KEY_NAME_DEFAULT="lazycat_ca_ed25519"
CA_KEY_PATH="${SSH_DIR}/${CA_KEY_NAME_DEFAULT}"
CA_PUB_PATH="${CA_KEY_PATH}.pub"
CA_CERT_PATH="${CA_KEY_PATH}-cert.pub"

lc_print_header() {
  lc_log ""
  lc_log "=== LazyCat SSH 管理器（控制端）==="
  lc_log ""
}

lc_require_not_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    lc_die "请不要使用 sudo 运行控制端脚本（它会修改当前用户的 ~/.ssh）。"
  fi
}

lc_self_install_if_needed() {
  local target_bin="${LAZYCAT_SSH_BIN_DIR}/lazycat-ssh"
  local installed=0
  local self_path="${BASH_SOURCE[0]-}"

  if [[ -x "$target_bin" ]]; then
    installed=1
  fi

  # 如果已安装，且当前脚本不是已安装的那一个（说明是通过 curl 或其它路径运行的），则进行更新
  if [[ $installed -eq 1 ]]; then
     if [[ -z "$self_path" ]] || [[ "$self_path" != "$target_bin" ]]; then
       lc_log "🔄 检测到本地已安装脚本，正在更新..."
     else
       return 0
     fi
  else
    lc_log "🔧 检测到未安装命令，准备安装到: ${target_bin}"
  fi

  lc_log "   安装目录: ${LAZYCAT_SSH_HOME}"

  # 只有首次安装需要确认，更新默认自动进行（除非用户在上面逻辑中被过滤掉）
  if [[ $installed -eq 0 ]]; then
    if ! lc_confirm "确认安装到本地用户目录（不会修改系统级文件）？" "Y"; then
      lc_die "用户取消安装。"
    fi
  fi

  mkdir -p "${LAZYCAT_SSH_BIN_DIR}"
  mkdir -p "${LAZYCAT_SSH_HOME}/lib"

  # 安装 common.sh
  local lib_src=""
  if [[ -n "${BASH_SOURCE[0]-}" ]] && [[ -f "${BASH_SOURCE[0]-}" ]]; then
    local potential_lib_dir
    potential_lib_dir="$(dirname "${BASH_SOURCE[0]-}")/../lib"
    if [[ -d "$potential_lib_dir" ]] && [[ -f "$potential_lib_dir/common.sh" ]]; then
       lib_src="$(cd "$potential_lib_dir" && pwd)/common.sh"
    fi
  fi
  if [[ -n "$lib_src" ]] && [[ -f "$lib_src" ]]; then
    cp "$lib_src" "${LAZYCAT_SSH_HOME}/lib/common.sh"
  else
    lc_need_cmd curl
    curl -fsSL "$REMOTE_LIB_URL" -o "${LAZYCAT_SSH_HOME}/lib/common.sh"
  fi
  chmod 755 "${LAZYCAT_SSH_HOME}/lib/common.sh"

  # 安装 client 脚本（本体）
  if [[ -n "${BASH_SOURCE[0]-}" ]] && [[ -f "${BASH_SOURCE[0]-}" ]] && [[ "${BASH_SOURCE[0]-}" != *"/bin/bash" ]]; then
    cp "${BASH_SOURCE[0]-}" "$target_bin"
  else
    lc_need_cmd curl
    curl -fsSL "$REMOTE_CLIENT_URL" -o "$target_bin"
  fi
  chmod 755 "$target_bin"

  if [[ $installed -eq 0 ]]; then
    lc_log "✅ 安装完成：${target_bin}"
    if [[ ":$PATH:" != *":${LAZYCAT_SSH_BIN_DIR}:"* ]]; then
      lc_log ""
      lc_log "⚠️  提示：你的 PATH 中似乎不包含 ${LAZYCAT_SSH_BIN_DIR}"
      lc_log "   你可以重启终端，或手动将其加入 PATH。"
    fi
  else
    lc_log "✅ 脚本已更新为最新版本。"
  fi
  lc_log ""
}

lc_uninstall_all() {
  lc_require_not_root
  
  lc_log "⚠️  即将执行完整卸载操作..."
  if ! lc_confirm "确认移除 LazyCat SSH 所有配置、证书及后台服务？" "N"; then
    return 0
  fi

  lc_uninstall_renew_timer
  lc_remove_shell_alias
  lc_uninstall

  if [[ -f "${LAZYCAT_SSH_BIN_DIR}/lazycat-ssh" ]]; then
    if lc_confirm "是否同时删除命令脚本文件 (${LAZYCAT_SSH_BIN_DIR}/lazycat-ssh)？" "Y"; then
      rm -f "${LAZYCAT_SSH_BIN_DIR}/lazycat-ssh"
      lc_log "✅ 已删除脚本文件。"
    fi
  fi
  
  lc_log "👋 卸载完成。"
}

lc_meta_write() {
  local gist_url="${1:-}"
  local raw_url="${2:-}"
  local file_name="${3:-}"

  mkdir -p "$META_DIR"
  umask 077

  {
    printf "GIST_URL=%q\n" "$gist_url"
    printf "RAW_URL=%q\n" "$raw_url"
    printf "FILE_NAME=%q\n" "$file_name"
  } >"${META_PATH}.tmp"
  mv "${META_PATH}.tmp" "$META_PATH"
  chmod 600 "$META_PATH"
}

# Decode the data forms emitted by Bash printf %q; never evaluate shell code.
lc_meta_decode() {
  local input="$1" output="" ch next escape decoded digits ansi=0
  if [[ "$input" == "''" ]]; then LC_META_VALUE="";return 0;fi
  if [[ "${input:0:2}" == "\$'" && "${input: -1}" == "'" ]]; then
    ansi=1;input="${input:2:${#input}-3}"
  fi
  while [[ -n "$input" ]]; do
    ch="${input:0:1}";input="${input:1}"
    if [[ "$ch" == '\' ]]; then
      [[ -n "$input" ]] || return 1
      next="${input:0:1}";input="${input:1}"
      if [[ "$ansi" == 0 ]]; then output+="$next";continue;fi
      case "$next" in
        "'") output+="'" ;;
        '\') output+='\' ;;
        a|b|e|E|f|n|r|t|v) printf -v decoded '%b' "\\$next";output+="$decoded" ;;
        [0-7])
          digits="$next"
          while [[ ${#digits} -lt 3 && "${input:0:1}" == [0-7] ]]; do digits+="${input:0:1}";input="${input:1}";done
          [[ "$digits" != 0 && "$digits" != 00 && "$digits" != 000 ]] || return 1
          printf -v decoded '%b' "\\0$digits";output+="$decoded" ;;
        *) return 1 ;;
      esac
    else
      if [[ "$ansi" == 0 ]]; then
        case "$ch" in [[:space:]]|'$'|'`'|'"'|"'"|'('|')'|';'|'&'|'|'|'<'|'>') return 1 ;; esac
      elif [[ "$ch" == "'" ]]; then return 1
      fi
      output+="$ch"
    fi
  done
  [[ "$output" != *[[:cntrl:]]* ]] || return 1
  LC_META_VALUE="$output"
}

lc_meta_load() {
  [[ -f "$META_PATH" && ! -L "$META_PATH" ]] || return 1
  local line key value seen="|" gist="" raw="" filename=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" == *=* ]] || { lc_log "meta.env 不是受支持的数据格式，未执行其中内容。";return 1; }
    key="${line%%=*}";value="${line#*=}"
    case "$key" in GIST_URL|RAW_URL|FILE_NAME) ;; *) return 1 ;; esac
    [[ "$seen" != *"|$key|"* ]] || return 1
    seen+="$key|"
    lc_meta_decode "$value" || { lc_log "meta.env 数据格式需要检查，未执行其中内容。";return 1; }
    case "$key" in GIST_URL) gist="$LC_META_VALUE" ;; RAW_URL) raw="$LC_META_VALUE" ;; FILE_NAME) filename="$LC_META_VALUE" ;; esac
  done < "$META_PATH"
  GIST_URL="$gist";RAW_URL="$raw";FILE_NAME="$filename"
}

lc_gist_open_guide() {
  lc_log ""
  lc_log "Gist 创建指引："
  lc_log "1) 打开 https://gist.new"
  lc_log "2) 选择 Secret Gist"
  lc_log "3) 新建一个文件（文件名任意，建议：lazycat-ssh.yaml）"
  lc_log "4) 按文档说明填入 YAML 并保存"
  lc_log "5) 复制 Gist 页面 URL（或 raw URL）回填到脚本"
  lc_log ""
  lc_log "文档（包含完整示例与字段解释）："
  lc_log "https://github.com/KroMiose/LazyCat-Scripts/blob/main/ssh/README.md"
  lc_log ""
}

lc_normalize_gist_input_url() {
  # 支持用户粘贴：
  # - Gist 页面 URL： https://gist.github.com/<user>/<id>
  # - raw URL：      https://gist.githubusercontent.com/.../raw/.../file.yaml
  # - embed 代码：    <script src="https://gist.github.com/<user>/<id>.js"></script>
  # - gist js URL：  https://gist.github.com/<user>/<id>.js
  local input="$1"
  local url="$input"

  # 去掉首尾空白
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"

  # 如果是 embed 代码，提取 src
  if [[ "$url" == *"<script"* ]] && [[ "$url" == *"src="* ]]; then
    if [[ "$url" =~ src=\"([^\"]+)\" ]]; then
      url="${BASH_REMATCH[1]}"
    fi
  fi

  # 如果是 gist 的 js URL，把它还原成页面 URL
  # https://gist.github.com/<user>/<id>.js -> https://gist.github.com/<user>/<id>
  if [[ "$url" =~ ^https?://gist\.github\.com/([^/]+)/([0-9a-fA-F]+)\.js($|\?) ]]; then
    url="https://gist.github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi

  printf '%s\n' "$url"
}

lc_parse_gist_json_select_file() {
  local gist_url="$1"
  local gist_base="${gist_url%%#*}"
  gist_base="${gist_base%/}"

  # Extract Gist ID: last component of the path
  local gist_id="${gist_base##*/}"
  # Remove potential suffixes if user pasted a derived URL
  gist_id="${gist_id%.js}"
  gist_id="${gist_id%.json}"
  gist_id="${gist_id%.git}"

  # Use GitHub API
  local json_url="https://api.github.com/gists/${gist_id}"

  local tmp_json
  tmp_json="$(mktemp)"
  trap 'rm -f "$tmp_json"' RETURN

  lc_need_cmd curl
  lc_log "⏳ 正在获取 Gist 信息..." >&2
  if ! curl -fsSL "$json_url" -o "$tmp_json"; then
    lc_die "无法获取 Gist 信息：${json_url}。请确认你粘贴的是 Gist 页面 URL（不是 embed 代码）。"
  fi

  # files: keys
  local files
  files="$(yq -r '.files | keys | .[]' "$tmp_json")"
  if [[ -z "$files" ]]; then
    lc_die "无法从 Gist JSON 中解析文件列表，请确认 URL 是否为 Gist 页面地址。"
  fi

  # 优先展示 yaml/yml
  local yaml_files=()
  local other_files=()
  while IFS= read -r f; do
    if [[ "$f" == *.yml ]] || [[ "$f" == *.yaml ]]; then
      yaml_files+=("$f")
    else
      other_files+=("$f")
    fi
  done <<<"$files"

  local shown=()
  if [[ ${#yaml_files[@]} -gt 0 ]]; then
    shown=("${yaml_files[@]}")
  else
    shown=("${other_files[@]}")
  fi

  lc_log "" >&2
  lc_log "请选择要使用的配置文件：" >&2
  local i=1
  for f in "${shown[@]}"; do
    lc_log "  ${i}) ${f}" >&2
    i=$((i + 1))
  done
  lc_log "" >&2

  local choice=""
  read -r -p "请输入编号（直接回车取消）: " choice
  if [[ -z "$choice" ]]; then
    lc_die "用户取消。"
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "${#shown[@]}" ]]; then
    lc_die "无效选择: $choice"
  fi

  local picked="${shown[$((choice - 1))]}"
  local raw_url
  FILE_NAME="$picked" raw_url="$(FILE_NAME="$picked" yq -r '.files[env(FILE_NAME)].raw_url' "$tmp_json")"
  if [[ -z "$raw_url" ]] || [[ "$raw_url" == "null" ]]; then
    lc_die "无法解析 raw_url（文件: ${picked}）。"
  fi

  printf '%s\n' "$picked|$raw_url"
}

lc_configure_gist() {
  lc_install_yq
  lc_need_cmd curl

  lc_gist_open_guide

  local url=""
  read -r -p "请粘贴 Gist 页面 URL 或 raw URL（回车取消）: " url
  if [[ -z "$url" ]]; then
    lc_die "用户取消。"
  fi

  url="$(lc_normalize_gist_input_url "$url")"
  url="${url%%[[:space:]]*}"

  local raw_url=""
  local gist_url=""
  local file_name=""

  if [[ "$url" == *"gist.githubusercontent.com"*"/raw/"* ]]; then
    raw_url="$url"
    gist_url=""
    file_name=""
  else
    gist_url="$url"
    local selected
    selected="$(lc_parse_gist_json_select_file "$gist_url")"
    file_name="${selected%%|*}"
    raw_url="${selected#*|}"
  fi

  lc_meta_write "$gist_url" "$raw_url" "$file_name"
  lc_log ""
  lc_log "✅ 已保存配置："
  [[ -n "$gist_url" ]] && lc_log "  - GIST_URL: $gist_url"
  lc_log "  - RAW_URL : $raw_url"
  [[ -n "$file_name" ]] && lc_log "  - FILE    : $file_name"
  lc_log ""
}

lc_validate_alias() {
  local alias="$1"
  if ! [[ "$alias" =~ ^[A-Za-z0-9._-]+$ ]]; then
    lc_die "Host alias 不合法（仅允许 A-Za-z0-9._-）：${alias}"
  fi
}

lc_validate_default_route() {
  local route="${1:-}"
  if [[ -z "$route" ]] || [[ "$route" == "null" ]]; then
    lc_die "default_route 不能为空（可选：lan / wan / tun）。"
  fi
  case "$route" in
    lan|wan|tun) return 0 ;;
    *) lc_die "default_route 不合法（可选：lan / wan / tun）：${route}" ;;
  esac
}

lc_route_priority() {
  # 规则约定：
  # - default_route=lan：lan > tun > wan
  # - default_route=wan：wan > tun > lan
  # - default_route=tun：tun > wan > lan
  local route="${1:-lan}"
  case "$route" in
    lan) printf '%s\n' lan tun wan ;;
    wan) printf '%s\n' wan tun lan ;;
    tun) printf '%s\n' tun wan lan ;;
    *) printf '%s\n' lan tun wan ;;
  esac
}

lc_append_ssh_host_block() {
  local out_path="$1"
  local host_alias="$2"
  local host_name="$3"
  local user="$4"
  local port="$5"
  local via="$6"
  local identity="$7"
  local ca_enabled="$8"

  local value
  for value in "$host_alias" "$host_name" "$user" "$port" "$via" "$identity"; do
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || lc_die "SSH 字段必须为单行文本。"
  done
  [[ "$host_alias" =~ ^[A-Za-z0-9._-]+$ && "$host_name" =~ ^[A-Za-z0-9._:%-]+$ ]] || lc_die "SSH 别名或主机名无效。"
  [[ -z "$port" ]] || { [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port > 0 && 10#$port <= 65535 )); } || lc_die "SSH 端口无效。"
  [[ "$identity" != *'"'* && "$identity" != *'\'* ]] || lc_die "IdentityFile 路径包含不支持的字符。"
  {
    printf 'Host %s\n' "$host_alias"
    printf '    HostName %s\n' "$host_name"
    # 让 known_hosts 以 alias 为主键，避免同域名/同端口复用引发冲突
    printf '    HostKeyAlias %s\n' "$host_alias"
    [[ -n "$user" ]] && printf '    User %s\n' "$user"
    [[ -n "$port" ]] && printf '    Port %s\n' "$port"
    [[ -n "$via" ]] && printf '    ProxyJump %s\n' "$via"
    if [[ -n "$identity" ]]; then
      printf '    IdentityFile "%s"\n' "$identity"
    elif [[ "$ca_enabled" == "1" ]]; then
      printf '    IdentityFile "%s"\n' "$CA_KEY_PATH"
      printf '    CertificateFile %s\n' "$CA_CERT_PATH"
    fi
    printf '    IdentitiesOnly yes\n'
    printf '\n'
  } >>"$out_path"
}

lc_pick_best_jump_alias() {
  # 选择跳板应走哪条线路：
  # - req=lan：lan > tun > wan
  # - req=wan：wan > tun > lan
  # - req=tun：tun > wan > lan
  # 只要 `via` 存在，就尽量选择 `${via}-<route>`（且 via 主机确实配置了对应线路），否则回退 `${via}`。
  local tmp_yaml="$1"
  local via_alias="$2"
  local req_route="$3"

  local p=""
  case "$req_route" in
    lan) p="$(printf '%s\n' lan tun wan)" ;;
    wan) p="$(printf '%s\n' wan tun lan)" ;;
    tun) p="$(printf '%s\n' tun wan lan)" ;;
    *) p="$(printf '%s\n' lan tun wan)" ;;
  esac

  local r
  while IFS= read -r r; do
    local vh=""
    vh="$(VIA="$via_alias" yq -r ".hosts[env(VIA)].${r}_host // .hosts[env(VIA)].${r}Host // .hosts[env(VIA)].${r}.host // \"\"" "$tmp_yaml")"
    [[ "$vh" == "null" ]] && vh=""
    if [[ -n "$vh" ]]; then
      printf '%s\n' "${via_alias}-${r}"
      return 0
    fi
  done <<<"$p"

  printf '%s\n' "$via_alias"
}

lc_pick_fallback_target_route() {
  # 当用户请求的线路缺失时，选择目标机实际使用的线路（HostName 取该线路）：
  # 优先：lan > tun > wan（内网优先，适合“外部通过跳板打进内网”的用法）
  local lan_host="$1"
  local tun_host="$2"
  local wan_host="$3"

  if [[ -n "$lan_host" ]]; then
    printf '%s\n' "lan"
    return 0
  fi
  if [[ -n "$tun_host" ]]; then
    printf '%s\n' "tun"
    return 0
  fi
  if [[ -n "$wan_host" ]]; then
    printf '%s\n' "wan"
    return 0
  fi
  printf '%s\n' ""
}

lc_validate_principals() {
  # principals: comma-separated usernames, allow A-Za-z0-9._- only
  local principals="$1"
  if [[ -z "$principals" ]] || [[ "$principals" == "null" ]]; then
    lc_die "CA principals 不能为空。"
  fi
  if ! [[ "$principals" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]; then
    lc_die "CA principals 格式不合法（仅允许 A-Za-z0-9._-，逗号分隔）：${principals}"
  fi
}

lc_validate_validity() {
  # ssh-keygen -V supports 12h/7d etc; keep strict to reduce injection.
  local validity="$1"
  if [[ -z "$validity" ]] || [[ "$validity" == "null" ]]; then
    lc_die "CA 有效期（validity）不能为空。"
  fi
  if ! [[ "$validity" =~ ^[0-9]+[smhdw]$ ]]; then
    lc_die "CA 有效期格式不合法（示例：30m / 12h / 7d）：${validity}"
  fi
}

lc_validate_ca_ssh_host() {
  # 用户必须事先配置好：ssh <sshHost> 能直连 CA 服务器
  local host="$1"
  if [[ -z "$host" ]] || [[ "$host" == "null" ]]; then
    lc_die "ca.ssh_host 不能为空（例如：ca-server）。"
  fi
  if ! [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]]; then
    lc_die "ca.ssh_host 含非法字符：${host}"
  fi
}

lc_validate_remote_path() {
  # 远端路径用于拼接到远端命令行，必须严格限制字符集，避免注入
  local path="$1"
  if [[ -z "$path" ]] || [[ "$path" == "null" ]]; then
    lc_die "ca.ca_key_path 不能为空。"
  fi
  # 允许 /abs/path 或 ~/.relative/path
  if ! [[ "$path" =~ ^(/|~\/)[A-Za-z0-9._/-]+$ ]]; then
    lc_die "ca.ca_key_path 不合法（仅允许 /... 或 ~/....，且不含空格/引号等特殊字符）：${path}"
  fi
}

lc_ensure_ca_keypair() {
  lc_need_cmd ssh-keygen
  [[ ! -L "$SSH_DIR" && ! -L "$CA_KEY_PATH" && ! -L "$CA_PUB_PATH" && ! -L "$CA_CERT_PATH" ]] || lc_die "证书或密钥路径是符号链接，未修改。"
  if [[ ! -d "$SSH_DIR" ]]; then
    mkdir -p "$SSH_DIR" || return 1
    chmod 700 "$SSH_DIR" || return 1
  fi

  if [[ -f "$CA_KEY_PATH" ]] && [[ -f "$CA_PUB_PATH" ]]; then
    return 0
  fi

  [[ ! -e "$CA_KEY_PATH" && ! -e "$CA_PUB_PATH" ]] || lc_die "密钥对不完整，请检查已有文件；不会覆盖或重新生成。"
  lc_log "🔑 未检测到控制端证书密钥，正在生成：${CA_KEY_PATH}"
  ssh-keygen -t ed25519 -f "$CA_KEY_PATH" -N "" -C "lazycat-ssh-ca-key-$(whoami)@$(hostname -s)"
  chmod 600 "$CA_KEY_PATH"
  chmod 644 "$CA_PUB_PATH"
}

lc_ca_fetch_and_sign_cert() (
  # 读取 YAML 顶层 ca 配置，通过 SSH 在 CA 服务器上签发证书并拉回本机。
  lc_install_yq
  lc_need_cmd curl
  lc_need_cmd ssh

  lc_meta_load || lc_die "尚未配置 Gist/RAW_URL，请先运行“Gist 引导与配置”。"
  [[ -n "${RAW_URL:-}" ]] || lc_die "meta.env 中缺少 RAW_URL，请重新配置。"

  local tmp_yaml="" cert_candidate="" remote_dir=""
  trap 'rm -f -- "$tmp_yaml" "$cert_candidate"; if [[ -n "$remote_dir" ]]; then "${ssh_base[@]}" "rm -rf \"${remote_dir}\"" || printf "%s\n" "远端临时目录清理失败：$remote_dir" >&2; fi' EXIT
  tmp_yaml="$(mktemp)" || return 1

  lc_log "⏳ 正在拉取配置（用于读取 CA 参数）..."
  curl -fsSL "$RAW_URL" -o "$tmp_yaml" || return 1
  [[ "$(yq -r '.version // ""' "$tmp_yaml")" == 1 ]] || lc_die '仅支持 YAML version: 1，未请求签发。'

  local ca_ssh_host ca_key_path ca_principals ca_validity
  # 约定：用户必须先配置好 `ssh <sshHost>` 能直连 CA 服务器
  # 推荐字段：ca.ssh_host；兼容旧字段：ca.sshHost / ca.host
  ca_ssh_host="$(yq -r '.ca.ssh_host // .ca.sshHost // .ca.host // ""' "$tmp_yaml")"
  lc_validate_ca_ssh_host "$ca_ssh_host"

  # 默认路径：lazycat-ssh-ca 初始化后的默认位置（减少暴露细节）
  ca_key_path="$(yq -r '.ca.ca_key_path // .ca.caKeyPath // "~/.lazycat/ssh-ca/lazycat-ssh-ca"' "$tmp_yaml")"
  lc_validate_remote_path "$ca_key_path"
  if [[ "$ca_key_path" == '~/'* ]]; then
    local remote_home
    remote_home="$(ssh -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o BatchMode=yes -o ConnectTimeout=10 "$ca_ssh_host" 'printf "%s" "$HOME"')"
    [[ "$remote_home" == /* && "$remote_home" != *$'\n'* ]] || lc_die "远端家目录无效。"
    ca_key_path="$remote_home/${ca_key_path:2}"
    lc_validate_remote_path "$ca_key_path"
  fi

  ca_principals="$(yq -r '.ca.principals // "root"' "$tmp_yaml")"
  ca_validity="$(yq -r '.ca.validity // "12h"' "$tmp_yaml")"

  lc_validate_principals "$ca_principals"
  lc_validate_validity "$ca_validity"

  lc_ensure_ca_keypair

  # - StrictHostKeyChecking=yes：未知主机直接失败（请先手动 ssh 一次写入 known_hosts）
  # - BatchMode=yes：任何需要交互输入的场景直接失败
  # - ConnectTimeout：避免长时间卡住
  local ssh_base=(ssh -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o BatchMode=yes -o ConnectTimeout=10)
  ssh_base+=( "${ca_ssh_host}" )

  lc_log "⏳ 正在向 CA 服务器请求签发证书（${ca_ssh_host}，有效期：${ca_validity}，principals：${ca_principals}）..."

  remote_dir="$("${ssh_base[@]}" "mktemp -d")"
  if [[ -z "$remote_dir" ]]; then
    lc_die "在 CA 服务器上创建临时目录失败。"
  fi

  "${ssh_base[@]}" "cat > \"${remote_dir}/key.pub\"" <"$CA_PUB_PATH"

  local cert_identity
  cert_identity="lazycat-ssh-$(whoami)@$(hostname -s)"

  "${ssh_base[@]}" "ssh-keygen -s \"${ca_key_path}\" -I \"${cert_identity}\" -n \"${ca_principals}\" -V \"+${ca_validity}\" \"${remote_dir}/key.pub\""

  cert_candidate="$(mktemp "${CA_CERT_PATH}.XXXXXX")" || return 1
  local cert_mode=644
  if [[ -f "$CA_CERT_PATH" ]]; then
    if [[ "$(uname -s)" == Darwin ]]; then
      cert_mode="$(stat -f '%Lp' "$CA_CERT_PATH")" || return 1
    else
      cert_mode="$(stat -c '%a' "$CA_CERT_PATH")" || return 1
    fi
    cp -p "$CA_CERT_PATH" "$cert_candidate" || return 1
  fi
  chmod u+w "$cert_candidate" || return 1
  "${ssh_base[@]}" "cat \"${remote_dir}/key-cert.pub\"" >"$cert_candidate" || return 1
  local expected_key candidate_key
  expected_key="$(ssh-keygen -lf "$CA_PUB_PATH" | awk '{print $2}')" || return 1
  candidate_key="$(ssh-keygen -lf "$cert_candidate" | awk '{print $2}')" || return 1
  [[ -n "$candidate_key" && "$candidate_key" == "$expected_key" ]] || lc_die "返回证书不属于当前公钥；旧证书保留。"
  ssh-keygen -L -f "$cert_candidate" >/dev/null || return 1
  "${ssh_base[@]}" "rm -rf \"${remote_dir}\"" || return 1
  remote_dir=""
  chmod "$cert_mode" "$cert_candidate" || return 1
  mv "$cert_candidate" "$CA_CERT_PATH" || return 1
  cert_candidate=""

  lc_log "✅ 证书已更新：${CA_CERT_PATH}"
)

lc_sync_from_raw_url() (
  trap 'rm -f -- "${tmp_yaml:-}" "${tmp_json:-}" "${out:-}" "${tmp_config:-}"' EXIT
  lc_install_yq
  lc_need_cmd curl

  lc_meta_load || lc_die "尚未配置 Gist/RAW_URL，请先运行“Gist 引导与配置”。"
  
  # 尝试动态解析最新的 RAW_URL (如果有 GIST_URL 和 FILE_NAME)
  if [[ -n "${GIST_URL:-}" ]] && [[ -n "${FILE_NAME:-}" ]]; then
    lc_log "🔄 正在检查 Gist 最新版本..."
    local gist_base="${GIST_URL%%#*}"
    gist_base="${gist_base%/}"
    local gist_id="${gist_base##*/}"
    # Remove potential suffixes
    gist_id="${gist_id%.json}"
    gist_id="${gist_id%.git}"
    
    local json_url="https://api.github.com/gists/${gist_id}"
    local tmp_json
    tmp_json="$(mktemp)"
    
    if curl -fsSL "$json_url" -o "$tmp_json"; then
       local latest_raw_url
       latest_raw_url="$(FILE_NAME="$FILE_NAME" yq -r '.files[env(FILE_NAME)].raw_url' "$tmp_json")"
       
       if [[ -n "$latest_raw_url" ]] && [[ "$latest_raw_url" != "null" ]]; then
         if [[ "$latest_raw_url" != "$RAW_URL" ]]; then
           lc_log "   发现新版本，更新 RAW_URL..."
           RAW_URL="$latest_raw_url"
           # 更新本地 meta 文件
           lc_meta_write "$GIST_URL" "$RAW_URL" "$FILE_NAME"
         fi
       fi
    else
       lc_log "⚠️  无法连接 GitHub API 获取最新版本，将使用本地缓存的 URL。"
    fi
    rm -f "$tmp_json"
  fi

  if [[ -z "${RAW_URL:-}" ]]; then
    lc_die "meta.env 中缺少 RAW_URL，请重新配置。"
  fi

  local tmp_yaml
  tmp_yaml="$(mktemp)"

  lc_log "⏳ 正在拉取配置..."
  curl -fsSL "$RAW_URL" -o "$tmp_yaml"

  # schema 校验
  local version
  version="$(yq -r '.version // ""' "$tmp_yaml")"
  if [[ "$version" != 1 ]]; then
    lc_die "仅支持 YAML version: 1。"
  fi
  local hosts_type
  hosts_type="$(yq -r '.hosts | tag' "$tmp_yaml")"
  if [[ "$hosts_type" != "!!map" ]]; then
    lc_die "YAML hosts 必须为 map（如：hosts: { alias: {...} }）。"
  fi

  local aliases
  aliases="$(yq -r '.hosts | keys | .[]' "$tmp_yaml")"
  if [[ -z "$aliases" ]]; then
    lc_die "hosts 为空。"
  fi

  local default_route
  default_route="$(yq -r '.default_route // .defaultRoute // "lan"' "$tmp_yaml")"
  if [[ -z "$default_route" ]] || [[ "$default_route" == "null" ]]; then
    default_route="lan"
  fi
  lc_validate_default_route "$default_route"

  # 可选 CA：若配置了 ca.host 则启用证书模式，并在 sync 时自动续期一次
  local ca_enabled="0"
  local ca_host
  ca_host="$(yq -r '.ca.ssh_host // .ca.sshHost // .ca.host // ""' "$tmp_yaml")"
  if [[ -n "$ca_host" ]] && [[ "$ca_host" != "null" ]]; then
    ca_enabled="1"
    lc_log "🔐 检测到 CA 配置，将启用证书模式（短有效期推荐安装后台自动续期）。"
  fi

  local out
  out="$(mktemp)"

  {
    printf '# Generated by LazyCat SSH (do not edit manually)\n'
    printf '# Source: %s\n' "${RAW_URL}"
    printf '# default_route: %s\n' "${default_route}"
    printf '\n'
  } >"$out"

  while IFS= read -r alias; do
    lc_validate_alias "$alias"
    local user via identity
    local legacy_host legacy_port
    local lan_host lan_port lan_via
    local wan_host wan_port wan_via
    local tun_host tun_port tun_via

    legacy_host="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].host // ""' "$tmp_yaml")"
    [[ "$legacy_host" == "null" ]] && legacy_host=""
    legacy_port="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].port // ""' "$tmp_yaml")"
    [[ "$legacy_port" == "null" ]] && legacy_port=""

    user="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].user // ""' "$tmp_yaml")"
    via="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].via // ""' "$tmp_yaml")"
    identity="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].identityFile // ""' "$tmp_yaml")"
    [[ "$user" == "null" ]] && user=""
    [[ "$via" == "null" ]] && via=""
    [[ "$identity" == "null" ]] && identity=""

    lan_host="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].lan_host // .hosts[env(ALIAS)].lanHost // .hosts[env(ALIAS)].lan.host // ""' "$tmp_yaml")"
    lan_port="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].lan_port // .hosts[env(ALIAS)].lanPort // .hosts[env(ALIAS)].lan.port // ""' "$tmp_yaml")"
    lan_via="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].lan_via // .hosts[env(ALIAS)].lanVia // .hosts[env(ALIAS)].lan.via // ""' "$tmp_yaml")"
    [[ "$lan_host" == "null" ]] && lan_host=""
    [[ "$lan_port" == "null" ]] && lan_port=""
    [[ "$lan_via" == "null" ]] && lan_via=""

    wan_host="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].wan_host // .hosts[env(ALIAS)].wanHost // .hosts[env(ALIAS)].wan.host // ""' "$tmp_yaml")"
    wan_port="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].wan_port // .hosts[env(ALIAS)].wanPort // .hosts[env(ALIAS)].wan.port // ""' "$tmp_yaml")"
    wan_via="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].wan_via // .hosts[env(ALIAS)].wanVia // .hosts[env(ALIAS)].wan.via // ""' "$tmp_yaml")"
    [[ "$wan_host" == "null" ]] && wan_host=""
    [[ "$wan_port" == "null" ]] && wan_port=""
    [[ "$wan_via" == "null" ]] && wan_via=""

    tun_host="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].tun_host // .hosts[env(ALIAS)].tunHost // .hosts[env(ALIAS)].tun.host // ""' "$tmp_yaml")"
    tun_port="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].tun_port // .hosts[env(ALIAS)].tunPort // .hosts[env(ALIAS)].tun.port // ""' "$tmp_yaml")"
    tun_via="$(ALIAS="$alias" yq -r '.hosts[env(ALIAS)].tun_via // .hosts[env(ALIAS)].tunVia // .hosts[env(ALIAS)].tun.via // ""' "$tmp_yaml")"
    [[ "$tun_host" == "null" ]] && tun_host=""
    [[ "$tun_port" == "null" ]] && tun_port=""
    [[ "$tun_via" == "null" ]] && tun_via=""

    local multi_mode="0"
    if [[ -n "$lan_host" ]] || [[ -n "$wan_host" ]] || [[ -n "$tun_host" ]]; then
      multi_mode="1"
    fi

    if [[ "$multi_mode" == "0" ]]; then
      # 单线路模式（兼容旧配置）
      if [[ -z "$legacy_host" ]]; then
        lc_die "hosts.${alias}.host 缺失。若要使用多线路模式，请至少配置 lan_host/wan_host/tun_host 之一。"
      fi
      lc_append_ssh_host_block "$out" "$alias" "$legacy_host" "$user" "$legacy_port" "$via" "$identity" "$ca_enabled"
      continue
    fi

    # 多线路模式：兼容旧字段 host/port -> wan_host/wan_port（仅当 wan_host 未显式配置时）
    if [[ -z "$wan_host" ]] && [[ -n "$legacy_host" ]]; then
      wan_host="$legacy_host"
      [[ -n "$legacy_port" ]] && wan_port="$legacy_port"
    fi

    local base_route=""
    local r
    while IFS= read -r r; do
      case "$r" in
        lan) [[ -n "$lan_host" ]] && base_route="lan" ;;
        wan) [[ -n "$wan_host" ]] && base_route="wan" ;;
        tun) [[ -n "$tun_host" ]] && base_route="tun" ;;
      esac
      [[ -n "$base_route" ]] && break
    done < <(lc_route_priority "$default_route")
    if [[ -z "$base_route" ]]; then
      lc_die "hosts.${alias} 未配置任何可用线路：请至少配置 lan_host / wan_host / tun_host 之一。"
    fi

    local base_host="" base_port="" base_via=""
    case "$base_route" in
      lan)
        base_host="$lan_host"
        base_port="$lan_port"
        base_via="$lan_via"
        ;;
      wan)
        base_host="$wan_host"
        base_port="$wan_port"
        base_via="$wan_via"
        ;;
      tun)
        base_host="$tun_host"
        base_port="$tun_port"
        base_via="$tun_via"
        ;;
    esac

    # 不带后缀的主 alias（由 default_route 决定优先线路）
    lc_append_ssh_host_block "$out" "$alias" "$base_host" "$user" "$base_port" "$base_via" "$identity" "$ca_enabled"

    # 各线路别名（-lan/-wan/-tun）
    #
    # 语义：
    # - 如果该线路存在（lan_host/wan_host/tun_host），则直接走该线路，不自动套 ProxyJump（除非配置了 <route>_via）。
    # - 如果该线路不存在，但配置了 via，则认为“必要时可通过跳板访问”：
    #   例如：仅配置 lan_host + via，用户 `ssh <alias>-tun` 时，将自动生成：
    #   - HostName=<lan_host>
    #   - ProxyJump=<via>-tun（若 via 主机有 tun 线路）或回退 <via>
    local req_route=""
    for req_route in lan wan tun; do
      local req_host="" req_port="" req_via=""
      case "$req_route" in
        lan)
          req_host="$lan_host"
          req_port="$lan_port"
          req_via="$lan_via"
          ;;
        wan)
          req_host="$wan_host"
          req_port="$wan_port"
          req_via="$wan_via"
          ;;
        tun)
          req_host="$tun_host"
          req_port="$tun_port"
          req_via="$tun_via"
          ;;
      esac

      if [[ -n "$req_host" ]]; then
        # 该线路存在：直连（除非显式配置了 <route>_via）
        lc_append_ssh_host_block "$out" "${alias}-${req_route}" "$req_host" "$user" "$req_port" "$req_via" "$identity" "$ca_enabled"
        continue
      fi

      # 该线路不存在：仅在存在 via 时生成“跳板访问”的别名
      if [[ -z "$via" ]]; then
        continue
      fi

      local fb_route
      fb_route="$(lc_pick_fallback_target_route "$lan_host" "$tun_host" "$wan_host")"
      if [[ -z "$fb_route" ]]; then
        continue
      fi

      local fb_host="" fb_port=""
      case "$fb_route" in
        lan) fb_host="$lan_host"; fb_port="$lan_port" ;;
        tun) fb_host="$tun_host"; fb_port="$tun_port" ;;
        wan) fb_host="$wan_host"; fb_port="$wan_port" ;;
      esac

      local jump_alias
      jump_alias="$(lc_pick_best_jump_alias "$tmp_yaml" "$via" "$req_route")"

      lc_append_ssh_host_block "$out" "${alias}-${req_route}" "$fb_host" "$user" "$fb_port" "$jump_alias" "$identity" "$ca_enabled"
    done
  done <<<"$aliases"

  # Validate all inventory fields before requesting credentials or modifying
  # user directories. Existing SSH directory permissions belong to the user.
  if [[ "$ca_enabled" == 1 ]]; then lc_ca_fetch_and_sign_cert; fi
  (umask 077; mkdir -p "$SSH_DIR" "$SSH_CONFIG_D")
  umask 077
  mv "$out" "${LAZYCAT_CONF}.tmp"
  mv "${LAZYCAT_CONF}.tmp" "$LAZYCAT_CONF"
  chmod 600 "$LAZYCAT_CONF"

  # Ensure ~/.ssh/config exists and has include block
  touch "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"

  lc_backup_file "$SSH_CONFIG"
  lc_remove_marked_block "$SSH_CONFIG" "$LC_MARK_BEGIN_SSH_CONFIG" "$LC_MARK_END_SSH_CONFIG"

  local include_block="Include ${LAZYCAT_CONF}"
  
  # Prepend the block to the top of the file to ensure global scope
  local tmp_config
  tmp_config="$(mktemp)"
  {
    printf '%s\n' "$LC_MARK_BEGIN_SSH_CONFIG"
    printf '%s\n' "$include_block"
    printf '%s\n' "$LC_MARK_END_SSH_CONFIG"
    cat "$SSH_CONFIG"
  } > "$tmp_config"
  mv "$tmp_config" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"

  lc_log "✅ 同步完成："
  lc_log "  - 写入: ${LAZYCAT_CONF}"
  lc_log "  - 更新: ${SSH_CONFIG}（Include 标记块）"
  lc_log ""
)

lc_show_current() {
  if [[ -f "$LAZYCAT_CONF" ]]; then
    lc_log ""
    lc_log "---- ${LAZYCAT_CONF} ----"
    cat "$LAZYCAT_CONF"
    lc_log "-------------------------"
    lc_log ""
  else
    lc_log "尚未生成配置文件：${LAZYCAT_CONF}"
  fi
}

lc_open_gist() {
  if lc_meta_load && [[ -n "${GIST_URL:-}" ]]; then
    lc_open_url "$GIST_URL"
    return 0
  fi
  lc_log "尚未保存 GIST_URL（你可能直接填了 raw URL）。"
}

lc_renew_certs() {
  lc_require_not_root
  lc_ca_fetch_and_sign_cert
  lc_log ""
  lc_log "✅ 证书续期完成。"
}

lc_install_renew_timer() {
  lc_require_not_root

  local interval_minutes_default="30"
  local interval_minutes=""
  read -r -p "请输入自动续期间隔（分钟，默认: ${interval_minutes_default}）: " interval_minutes
  interval_minutes="${interval_minutes:-$interval_minutes_default}"
  if ! [[ "$interval_minutes" =~ ^[0-9]+$ ]] || [[ "$interval_minutes" -lt 1 ]]; then
    lc_die "无效间隔分钟数：${interval_minutes}"
  fi

  if ! lc_confirm "将为当前用户安装后台自动续期任务（可随时卸载），确认继续？" "Y"; then
    lc_die "用户取消。"
  fi

  # macOS: launchd
  if command -v launchctl >/dev/null 2>&1 && [[ "$(uname)" == "Darwin" ]]; then
    local plist_dir="$HOME/Library/LaunchAgents"
    local plist_path="${plist_dir}/com.lazycat.ssh.renew.plist"
    mkdir -p "$plist_dir"

    # 构建 PATH：包含常见的 yq 安装路径（brew 安装通常在 /opt/homebrew/bin 或 /usr/local/bin）
    local default_path="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    local homebrew_path=""
    if [[ -d "/opt/homebrew/bin" ]]; then
      homebrew_path="/opt/homebrew/bin:/opt/homebrew/sbin"
    elif [[ -d "/usr/local/bin" ]]; then
      homebrew_path="/usr/local/bin:/usr/local/sbin"
    fi
    local full_path="${homebrew_path:+${homebrew_path}:}${default_path}"
    # 也包含用户本地 bin（如果存在）
    if [[ -d "$HOME/.local/bin" ]]; then
      full_path="$HOME/.local/bin:${full_path}"
    fi

    cat >"${plist_path}.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.lazycat.ssh.renew</string>
  <key>ProgramArguments</key>
  <array>
    <string>${LAZYCAT_SSH_BIN_DIR}/lazycat-ssh</string>
    <string>renew-certs</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${full_path}</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>
  <key>StartInterval</key><integer>$((interval_minutes * 60))</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${HOME}/.lazycat/ssh/renew.log</string>
  <key>StandardErrorPath</key><string>${HOME}/.lazycat/ssh/renew.err.log</string>
</dict>
</plist>
EOF
    mv "${plist_path}.tmp" "$plist_path"

    launchctl unload "$plist_path" >/dev/null 2>&1 || true
    launchctl load "$plist_path"
    lc_log "✅ 已安装后台自动续期（launchd）：${plist_path}"
    return 0
  fi

  # Linux: systemd user timer
  if command -v systemctl >/dev/null 2>&1; then
    local user_dir="$HOME/.config/systemd/user"
    local service_path="${user_dir}/lazycat-ssh-renew.service"
    local timer_path="${user_dir}/lazycat-ssh-renew.timer"
    mkdir -p "$user_dir"

    cat >"${service_path}.tmp" <<EOF
[Unit]
Description=LazyCat SSH renew certificates

[Service]
Type=oneshot
ExecStart=${LAZYCAT_SSH_BIN_DIR}/lazycat-ssh renew-certs
EOF
    mv "${service_path}.tmp" "$service_path"

    cat >"${timer_path}.tmp" <<EOF
[Unit]
Description=LazyCat SSH renew certificates timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=${interval_minutes}min
Unit=lazycat-ssh-renew.service

[Install]
WantedBy=timers.target
EOF
    mv "${timer_path}.tmp" "$timer_path"

    systemctl --user daemon-reload
    systemctl --user enable --now lazycat-ssh-renew.timer
    lc_log "✅ 已安装后台自动续期（systemd 用户级）：lazycat-ssh-renew.timer"
    return 0
  fi

  lc_die "未检测到可用的 launchctl/systemctl，无法自动安装后台续期任务。你仍可手动运行：lazycat-ssh renew-certs"
}

lc_uninstall_renew_timer() {
  lc_require_not_root

  if command -v launchctl >/dev/null 2>&1 && [[ "$(uname)" == "Darwin" ]]; then
    local plist_path="$HOME/Library/LaunchAgents/com.lazycat.ssh.renew.plist"
    if [[ -f "$plist_path" ]]; then
      launchctl unload "$plist_path" >/dev/null 2>&1 || true
      rm -f "$plist_path"
      lc_log "✅ 已卸载后台自动续期（launchd）。"
    else
      lc_log "未找到 launchd 任务文件：${plist_path}"
    fi
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now lazycat-ssh-renew.timer >/dev/null 2>&1 || true
    rm -f "$HOME/.config/systemd/user/lazycat-ssh-renew.timer" "$HOME/.config/systemd/user/lazycat-ssh-renew.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    lc_log "✅ 已卸载后台自动续期（systemd 用户级）。"
    return 0
  fi

  lc_log "未检测到 launchctl/systemctl，当前无可卸载的自动续期任务。"
}

lc_uninstall() {
  lc_require_not_root
  if ! lc_confirm "将移除 LazyCat SSH 配置（可回滚，仍会创建备份），确认继续？" "N"; then
    lc_die "用户取消。"
  fi

  mkdir -p "$SSH_DIR"
  touch "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"

  lc_backup_file "$SSH_CONFIG"
  lc_remove_marked_block "$SSH_CONFIG" "$LC_MARK_BEGIN_SSH_CONFIG" "$LC_MARK_END_SSH_CONFIG"

  if [[ -f "$LAZYCAT_CONF" ]]; then
    rm -f "$LAZYCAT_CONF"
  fi
  if [[ -f "$META_PATH" ]]; then
    rm -f "$META_PATH"
  fi

  lc_log "✅ 已移除 LazyCat SSH 配置。"
}

lc_detect_profile() {
  local shell_type
  shell_type="$(basename "$SHELL")"
  local profile_file=""
  
  if [[ "$shell_type" == "zsh" ]]; then
    profile_file="$HOME/.zshrc"
  elif [[ "$shell_type" == "bash" ]]; then
    profile_file="$HOME/.bashrc"
  elif [[ -f "$HOME/.zshrc" ]]; then
    profile_file="$HOME/.zshrc"
  elif [[ -f "$HOME/.bashrc" ]]; then
    profile_file="$HOME/.bashrc"
  fi
  echo "$profile_file"
}

lc_register_shell_alias() {
  local profile_file
  profile_file="$(lc_detect_profile)"
  
  if [[ -z "$profile_file" ]]; then
    lc_err "❌ 未能自动检测到 Shell 配置文件 (.zshrc/.bashrc)，跳过别名注册。"
    return 1
  fi

  local sync_cmd="lazycat-ssh sync"
  # 使用完整路径以防 PATH 问题
  if [[ -x "${LAZYCAT_SSH_BIN_DIR}/lazycat-ssh" ]]; then
    sync_cmd="${LAZYCAT_SSH_BIN_DIR}/lazycat-ssh sync"
  fi

  local alias_name="lazy-ssh-sync"
  local block_content="alias ${alias_name}='${sync_cmd}'"

  local begin_mark="# >>> LazyCat SSH Alias BEGIN >>>"
  local end_mark="# <<< LazyCat SSH Alias END <<<"

  lc_backup_file "$profile_file"
  lc_remove_marked_block "$profile_file" "$begin_mark" "$end_mark"
  lc_append_marked_block "$profile_file" "$begin_mark" "$block_content" "$end_mark"

  lc_log "✅ 已将快捷命令注册到: $profile_file"
  lc_log "   命令: ${alias_name}"
  lc_log "   请运行 'source $profile_file' 或重启终端以生效。"
}

lc_remove_shell_alias() {
  local profile_file
  profile_file="$(lc_detect_profile)"

  if [[ -z "$profile_file" || ! -f "$profile_file" ]]; then
    return 0
  fi

  local begin_mark="# >>> LazyCat SSH Alias BEGIN >>>"
  local end_mark="# <<< LazyCat SSH Alias END <<<"

  if grep -qF "$begin_mark" "$profile_file"; then
     lc_backup_file "$profile_file"
     lc_remove_marked_block "$profile_file" "$begin_mark" "$end_mark"
     lc_log "✅ 已从 $profile_file 移除快捷命令注册。"
  fi
}

main_menu() {
  lc_print_header

  while true; do
    # 每次循环重新加载 meta 以获取最新 GIST_URL
    lc_meta_load >/dev/null 2>&1 || true
    
    local gist_option_text="Gist 引导与配置（打开网页指引 + 回填 URL + 选择文件）"
    if [[ -n "${GIST_URL:-}" ]]; then
      local gist_id="${GIST_URL##*/}"
      # 简略显示 ID
      gist_option_text="更新 Gist 配置 (当前 ID: ${gist_id:0:8}...)"
    fi
    
    local renew_option_text="安装后台自动续期"
    local renew_installed=0
    if command -v launchctl >/dev/null 2>&1 && [[ "$(uname)" == "Darwin" ]]; then
       if [[ -f "$HOME/Library/LaunchAgents/com.lazycat.ssh.renew.plist" ]]; then renew_installed=1; fi
    elif command -v systemctl >/dev/null 2>&1; then
       if [[ -f "$HOME/.config/systemd/user/lazycat-ssh-renew.timer" ]]; then renew_installed=1; fi
    fi
    
    if [[ $renew_installed -eq 1 ]]; then
      renew_option_text="重新安装/更新后台自动续期 (状态: 已安装)"
    fi

    # 检测 Shell Alias
    local alias_option_text="注册快捷命令 'lazy-ssh-sync' 到终端"
    local alias_installed=0
    local profile_file
    profile_file="$(lc_detect_profile)"
    if [[ -n "$profile_file" ]] && [[ -f "$profile_file" ]] && grep -q "# >>> LazyCat SSH Alias BEGIN >>>" "$profile_file"; then
        alias_installed=1
        alias_option_text="移除快捷命令 'lazy-ssh-sync' (状态: 已注册)"
    fi

    lc_log "请选择操作："
    lc_log "  1) ${gist_option_text}"
    lc_log "  2) 同步配置并续签证书"
    lc_log "  3) 查看当前生成的 SSH 配置"
    lc_log "  4) 在浏览器中打开 Gist"
    lc_log "  5) ${renew_option_text}"
    lc_log "  6) ${alias_option_text}"
    lc_log "  7) 卸载 / 移除 LazyCat SSH 所有配置"
    lc_log ""
    
    local choice=""
    read -r -p "请输入编号 (回车退出): " choice
    lc_log ""
    
    if [[ -z "$choice" ]]; then
      exit 0
    fi
    
    case "${choice}" in
      1) lc_configure_gist ;;
      2) lc_sync_from_raw_url ;;
      3) lc_show_current ;;
      4) lc_open_gist ;;
      5) lc_install_renew_timer ;;
      6) 
         if [[ $alias_installed -eq 0 ]]; then
           lc_register_shell_alias
         else
           lc_remove_shell_alias
         fi 
         ;;
      7) lc_uninstall_all ;;
      *) lc_log "无效选项: ${choice}" ;;
    esac
  done
}

main() {
  lc_require_not_root
  if [[ "${1:-}" == check-source ]]; then lc_meta_load || lc_die "配置源数据无效或不存在";lc_log "配置源数据格式有效（未联网）";return;fi
  # 子命令：用于定时任务/脚本化
  case "${1:-}" in
    install) [[ $# == 1 ]] || lc_die 'install 不接受参数'; lc_install_yq --install; lc_self_install_if_needed ;;
    sync) lc_sync_from_raw_url ;;
    renew-certs) lc_renew_certs ;;
    install-renew) lc_install_renew_timer ;;
    uninstall-renew) lc_uninstall_renew_timer ;;
    "" ) main_menu ;;
    * ) lc_die "未知命令：$1（可用：install / sync / renew-certs / install-renew / uninstall-renew）" ;;
  esac
}

main "$@"
