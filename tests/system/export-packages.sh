#!/usr/bin/env bash
# Environment preparation only, run before installing ANY test observer.
set -euo pipefail
[[ "$(hostname)" == lazycat-fixture && "$(id -u)" == 0 ]]
export DEBIAN_FRONTEND=noninteractive
repo=/tmp/lazycat-package-export
mkdir -p "$repo/partial"
# A clean image's own trusted apt configuration resolves the complete closure.
# The host later locks every downloaded byte and URL; no package is installed here.
timeout 240 apt-get -o Acquire::Retries=0 -o Acquire::http::Timeout=25 -o Acquire::IndexTargets::deb-src::Sources::DefaultEnabled=false update
packages=(openssh-server sudo curl openssl zsh python3 git ca-certificates dbus-user-session squid apache2-utils docker.io)
apt-get -o "Dir::Cache::archives=$repo" --print-uris --download-only --reinstall install -y "${packages[@]}" > "$repo/uris.txt"
timeout 900 apt-get -o "Dir::Cache::archives=$repo" -o Acquire::Retries=0 -o Acquire::http::Timeout=25 --download-only --reinstall install -y "${packages[@]}"
: > "$repo/Packages"
for package in "$repo"/*.deb; do
    [[ -f "$package" ]]
    dpkg-deb --field "$package" >> "$repo/Packages"
    printf 'Filename: %s\nSize: %s\nSHA256: %s\n\n' "$(basename "$package")" "$(wc -c < "$package")" "$(sha256sum "$package" | cut -d' ' -f1)" >> "$repo/Packages"
done
echo 'PREPARED package downloads only; no product behavior has been verified'
