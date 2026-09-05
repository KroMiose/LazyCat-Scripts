#!/bin/sh
# 名称：codex-hud 稳定安装入口
# 功能：选择稳定版/指定版本，校验并调用该版本安装器。
# 平台：macOS / Linux；无需语言运行时或 sudo。
# 用法：sh install.sh [--version v0.1.0] [--no-setup] [--install-dir PATH]
set -eu
die() { printf 'codex-hud: %s\n' "$*" >&2; exit 1; }
hud_version=''
hud_mode=auto
hud_bin_dir="$HOME/.local/bin"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) [ "$#" -ge 2 ] || die '--version 缺少值'; hud_version=$2; shift 2 ;;
    --install-dir) [ "$#" -ge 2 ] || die '--install-dir 缺少值'; hud_bin_dir=$2; shift 2 ;;
    --no-setup) hud_mode=none; shift ;;
    --help|-h) printf '%s\n' 'sh install.sh [--version v0.1.0] [--no-setup] [--install-dir PATH]'; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done
case "$hud_bin_dir" in /*) ;; *) die '安装目录必须是绝对路径' ;; esac
if command -v curl >/dev/null 2>&1; then
  download() { curl -fLsS --connect-timeout 10 --max-time 120 "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  download() { wget -q --timeout=30 --tries=1 -O "$2" "$1"; }
else
  die '缺少 curl 或 wget；也可以在 GitHub Release 手动下载二进制'
fi
if command -v sha256sum >/dev/null 2>&1; then
  digest() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  digest() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v openssl >/dev/null 2>&1; then
  digest() { openssl dgst -sha256 "$1" | awk '{print $NF}'; }
else
  die '缺少 SHA-256 工具（sha256sum / shasum / openssl），未安装'
fi

umask 077
hud_tmp=$(mktemp -d "${TMPDIR:-/tmp}/codex-hud-bootstrap.XXXXXX")
trap 'rm -rf "$hud_tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
hud_release_base=${CODEX_HUD_RELEASE_BASE:-https://github.com/KroMiose/LazyCat-Scripts/releases/download}
if [ -z "$hud_version" ]; then
  if [ -n "${CODEX_HUD_RELEASE_BASE:-}" ] && [ -z "${CODEX_HUD_STABLE_URL:-}" ]; then
    die '自定义发布源必须同时设置 CODEX_HUD_STABLE_URL，或通过 --version 固定版本；不会混用官方源'
  fi
  hud_stable_url=${CODEX_HUD_STABLE_URL:-https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/codex-hud/stable.txt}
  download "$hud_stable_url" "$hud_tmp/stable.txt" || die '读取稳定版失败；可以 --version 指定已有版本'
  hud_version=$(cat "$hud_tmp/stable.txt")
  [ "$hud_version" != 'unreleased' ] || die '尚未发布稳定版，不会下载开发构建'
fi
case "$hud_version" in codex-hud-v*) ;; v*) hud_version="codex-hud-$hud_version" ;; *) hud_version="codex-hud-v$hud_version" ;; esac
printf '%s\n' "$hud_version" | LC_ALL=C grep -Eq '^codex-hud-v[0-9]+\.[0-9]+\.[0-9]+$' || die '版本必须是 v0.1.0 或 codex-hud-v0.1.0 格式'
case "$hud_version" in *'
'*) die '稳定版本文件必须只有一行' ;; esac
printf '选择版本：%s\n发布源：%s\n' "$hud_version" "$hud_release_base"
download "$hud_release_base/$hud_version/SHA256SUMS" "$hud_tmp/SHA256SUMS" || die '下载校验清单失败'
download "$hud_release_base/$hud_version/install.sh" "$hud_tmp/install.sh" || die '下载同版本安装器失败'
verify() {
  hud_expected=$(awk -v name="$2" '$2 == name {print $1}' "$hud_tmp/SHA256SUMS")
  [ "${#hud_expected}" -eq 64 ] || die "校验清单缺少或重复 $2"
  hud_actual=$(digest "$1")
  [ "$hud_actual" = "$hud_expected" ] || die "SHA-256 校验失败：$2，未安装"
}

verify "$hud_tmp/install.sh" install.sh
# Pass the exact selected tag. A mislabeled release installer is rejected before
# it installs anything; the installer itself never consults the stable pointer.
sh "$hud_tmp/install.sh" --expected-version "$hud_version" --install-dir "$hud_bin_dir" --mode "$hud_mode"
