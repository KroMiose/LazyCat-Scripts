#!/bin/sh
# 名称：codex-hud 版本安装器（构建时固定版本）
# 功能：校验同版本二进制，再由程序执行可回滚安装。
# 平台：macOS / Linux ARM64、AMD64。
# 用法：sh install.sh [--install-dir PATH] [--no-setup]
set -eu
die() { printf 'codex-hud: %s\n' "$*" >&2; exit 1; }
hud_version='@VERSION@'
hud_expected_version="$hud_version"
hud_bin_dir="$HOME/.local/bin"
hud_mode=auto
while [ "$#" -gt 0 ]; do
  case "$1" in
    --expected-version) [ "$#" -ge 2 ] || die '缺少版本'; hud_expected_version=$2; shift 2 ;;
    --install-dir) [ "$#" -ge 2 ] || die '缺少目录'; hud_bin_dir=$2; shift 2 ;;
    --mode) [ "$#" -ge 2 ] || die '缺少模式'; hud_mode=$2; shift 2 ;;
    --no-setup) hud_mode=none; shift ;;
    --help|-h) printf '%s\n' '版本安装器：[--install-dir PATH] [--no-setup]'; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done
[ "$hud_expected_version" = "$hud_version" ] || die '版本安装器与选择版本不一致，未安装'
printf '%s\n' "$hud_version" | LC_ALL=C grep -Eq '^codex-hud-v[0-9]+\.[0-9]+\.[0-9]+$' || die '此模板需经发布构建生成，不能直接安装'
case "$hud_mode" in auto|none) ;; *) die '无效安装模式' ;; esac
case "$hud_bin_dir" in /*) ;; *) die '安装目录必须是绝对路径' ;; esac
case "$(uname -s)" in Darwin) hud_os=darwin ;; Linux) hud_os=linux ;; *) die '仅支持 macOS / Linux' ;; esac
case "$(uname -m)" in arm64|aarch64) hud_arch=arm64 ;; x86_64|amd64) hud_arch=amd64 ;; *) die '仅支持 ARM64 / AMD64' ;; esac
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
mkdir -p "$hud_bin_dir"
hud_tmp=$(mktemp -d "$hud_bin_dir/.codex-hud-install.XXXXXX")
trap 'rm -rf "$hud_tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
hud_release_base=${CODEX_HUD_RELEASE_BASE:-https://github.com/KroMiose/LazyCat-Scripts/releases/download}
hud_asset="codex-hud-$hud_os-$hud_arch"
hud_url="$hud_release_base/$hud_version"
printf '下载 %s / %s\n' "$hud_version" "$hud_asset"
download "$hud_url/$hud_asset" "$hud_tmp/program" || die '下载失败，旧程序保留'
download "$hud_url/SHA256SUMS" "$hud_tmp/SHA256SUMS" || die '下载校验清单失败，旧程序保留'
verify() {
  hud_expected=$(awk -v name="$2" '$2 == name {print $1}' "$hud_tmp/SHA256SUMS")
  [ "${#hud_expected}" -eq 64 ] || die "校验清单缺少或重复 $2"
  hud_actual=$(digest "$1")
  [ "$hud_actual" = "$hud_expected" ] || die "SHA-256 校验失败：$2，未安装"
}

verify "$hud_tmp/program" "$hud_asset"
chmod 755 "$hud_tmp/program"
hud_reported=$("$hud_tmp/program" version) || die '候选程序无法运行，旧程序保留'
[ "$hud_reported" = "codex-hud $hud_version" ] || die '候选程序版本不匹配，旧程序保留'
"$hud_tmp/program" install-binary "$hud_bin_dir/codex-hud" "$hud_mode"
