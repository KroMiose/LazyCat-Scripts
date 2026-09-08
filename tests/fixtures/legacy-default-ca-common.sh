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
  # Remove block (inclusive) from file. If not present, no-op.
  # usage: lc_remove_marked_block "/path" "BEGIN_MARK" "END_MARK"
  local path="$1"
  local begin="$2"
  local end="$3"

  [[ -f "$path" ]] || return 0

  if ! grep -qF "$begin" "$path"; then
    return 0
  fi

  awk -v b="$begin" -v e="$end" '
    BEGIN {p=0}
    index($0, b) {p=1; next}
    index($0, e) {p=0; next}
    !p {print}
  ' "$path" >"${path}.tmp"
  mv "${path}.tmp" "$path"
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
    last_char="$(tail -c 1 "$path")"
    if [[ "$last_char" != $'\n' ]]; then
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
  # 首先尝试标准 PATH 检测
  if command -v yq >/dev/null 2>&1; then
    return 0
  fi

  # macOS: 尝试常见的 Homebrew 安装路径（launchd 环境可能 PATH 不完整）
  if [[ "$(uname)" == "Darwin" ]]; then
    local yq_candidates=(
      "/opt/homebrew/bin/yq"
      "/usr/local/bin/yq"
      "$HOME/.local/bin/yq"
      "$HOME/homebrew/bin/yq"
    )
    for candidate in "${yq_candidates[@]}"; do
      if [[ -x "$candidate" ]]; then
        # 找到 yq，但不在 PATH 中，临时添加到 PATH（仅本次调用有效）
        export PATH="$(dirname "$candidate"):${PATH}"
        if command -v yq >/dev/null 2>&1; then
          return 0
        fi
      fi
    done
  fi

  lc_log "🔧 未检测到 yq，正在尝试自动安装..."

  if command -v brew >/dev/null 2>&1; then
    brew install yq
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y yq
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y yq
    return 0
  fi

  if command -v yum >/dev/null 2>&1; then
    sudo yum install -y yq
    return 0
  fi

  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm yq
    return 0
  fi

  lc_die "无法自动安装 yq（未检测到 brew/apt-get/dnf/yum/pacman）。请先手动安装 yq 后重试。"
}

