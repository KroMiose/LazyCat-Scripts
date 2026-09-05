#!/bin/sh
# 名称：codex-hud Release 构建
# 功能：固定版本构建四个平台程序、版本安装器和完整校验清单。
# 平台：开发/CI 主机，要求 Go；用户无需运行本脚本。
# 用法：sh scripts/build-release.sh codex-hud-v0.1.0
set -eu
hud_tag=${1:?需要 codex-hud-vX.Y.Z 标签}
printf '%s\n' "$hud_tag" | LC_ALL=C grep -Eq '^codex-hud-v[0-9]+\.[0-9]+\.[0-9]+$' || exit 1
cd "$(dirname "$0")/.."
mkdir -p dist
for hud_os in darwin linux; do
  for hud_arch in arm64 amd64; do
    CGO_ENABLED=0 GOOS="$hud_os" GOARCH="$hud_arch" go build -trimpath -ldflags "-s -w -X main.version=$hud_tag" -o "dist/codex-hud-$hud_os-$hud_arch" .
  done
done
sed "s/@VERSION@/$hud_tag/g" release-install.sh > dist/install.sh
cp LICENSES.txt dist/LICENSES.txt
cd dist
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum codex-hud-darwin-amd64 codex-hud-darwin-arm64 codex-hud-linux-amd64 codex-hud-linux-arm64 install.sh LICENSES.txt > SHA256SUMS
else
  shasum -a 256 codex-hud-darwin-amd64 codex-hud-darwin-arm64 codex-hud-linux-amd64 codex-hud-linux-arm64 install.sh LICENSES.txt > SHA256SUMS
fi
