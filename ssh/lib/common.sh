#!/usr/bin/env bash
#
# ==============================================================================
# 名称: ssh/lib/common.sh
# 功能: LazyCat SSH 模块公共函数库（被 client/node/ca 脚本复用）
# 适用: Bash (macOS / Linux)
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

LC_MARK_BEGIN_SSH_CONFIG="# >>> LazyCat SSH BEGIN >>>"
LC_MARK_END_SSH_CONFIG="# <<< LazyCat SSH END <<<"

LC_MARK_BEGIN_SSHD_CONFIG="# >>> LazyCat SSH CA BEGIN >>>"
LC_MARK_END_SSHD_CONFIG="# <<< LazyCat SSH CA END <<<"

lc_ts() {
  date +'%Y-%m-%d_%H-%M-%S'
}

lc_log() {
  # shellcheck disable=SC2059
  printf '%s\n' "$*"
}

lc_err() {
  # shellcheck disable=SC2059
  printf '%s\n' "$*" >&2
}

lc_die() {
  lc_err "❌ $*"
  exit 1
}

lc_need_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || lc_die "缺少依赖命令: ${cmd}"
}

lc_confirm() {
  # usage: lc_confirm "question" "default" ; default in [Y|N]
  local prompt="$1"
  local default="${2:-N}"
  local answer=""

  if [[ "$default" == "Y" ]]; then
    read -r -p "${prompt} (Y/n): " answer
    answer="${answer:-Y}"
  else
    read -r -p "${prompt} (y/N): " answer
    answer="${answer:-N}"
  fi

  [[ "$answer" =~ ^[Yy]$ ]]
}

lc_backup_file() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  local bak="${path}.bak.$(lc_ts)"
  cp "$path" "$bak"
  lc_log "  -> 已创建备份: $bak"
}

lc_remove_marked_block() {
  local path="$1" begin="$2" end="$3" tmp
  [[ ! -L "$path" ]] || lc_die "拒绝修改符号链接: $path"
  [[ -f "$path" ]] || return 0
  # Validate before creating a candidate; a broken block must never eat user data.
  awk -v b="$begin" -v e="$end" '
    $0 == b { if (inside || starts++) exit 1; inside=1; next }
    $0 == e { if (!inside) exit 1; inside=0 }
    END { if (inside) exit 1 }
  ' "$path" || lc_die "托管标记损坏或重复，未修改: $path"
  grep -qxF "$begin" "$path" || return 0
  tmp="$(mktemp "${path}.XXXXXX")" || return 1
  cp -p "$path" "$tmp" || { rm -f "$tmp"; return 1; }
  if ! awk -v b="$begin" -v e="$end" '
    $0 == b { inside=1; next }
    $0 == e { inside=0; next }
    !inside { print }
  ' "$path" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$path"
}


lc_append_marked_block() {
  # Append a marked block at end of file, preceded by a newline.
  # usage: lc_append_marked_block "/path" "BEGIN" "CONTENT" "END"
  local path="$1"
  local begin="$2"
  local content="$3"
  local end="$4"

  mkdir -p "$(dirname "$path")"
  touch "$path"

  # Ensure file ends with newline before appending.
  if [[ -s "$path" ]]; then
    local last_char
    last_char="$(tail -c 1 "$path"; printf x)"
    if [[ "$last_char" != $'\nx' ]]; then
      printf '\n' >>"$path"
    fi
  fi

  printf '%s\n' "$begin" >>"$path"
  printf '%s\n' "$content" >>"$path"
  printf '%s\n' "$end" >>"$path"
}

lc_open_url() {
  local url="$1"
  if command -v open >/dev/null 2>&1; then
    open "$url"
    return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url"
    return 0
  fi
  lc_log "请在浏览器中打开: $url"
}

lc_install_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    if [[ "$(uname)" == Darwin ]]; then
      for candidate in /opt/homebrew/bin/yq /usr/local/bin/yq; do
        if [[ -x "$candidate" ]]; then export PATH="$(dirname "$candidate"):$PATH"; break; fi
      done
    fi
  fi
  if ! command -v yq >/dev/null 2>&1; then
    [[ "${1:-}" == --install ]] || lc_die "缺少 Mike Farah yq v4；请显式运行客户端 install 或自行安装依赖。日常命令不会安装软件。"
    command -v brew >/dev/null 2>&1 || lc_die "旧客户端需要 Mike Farah yq v4；请安装该实现或迁移 Go 客户端。不会安装同名但不兼容的软件包。"
    brew install yq || return 1
  fi
  [[ "$(printf 'hosts: {}\n' | yq -r '.hosts | tag')" == '!!map' ]] || lc_die "yq 实现不兼容，需要 Mike Farah yq v4。"
}
