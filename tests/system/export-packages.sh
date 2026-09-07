#!/usr/bin/env bash
# Environment preparation only, run before installing ANY test observer.
set -euo pipefail
[[ "$(hostname)" == lazycat-fixture && "$(id -u)" == 0 ]]
export DEBIAN_FRONTEND=noninteractive
printf 'package-export-indexes\n' > /tmp/lazycat-phase
repo=/tmp/lazycat-package-export
mkdir -p "$repo"
# Resolve through authenticated apt indices in the exact base image. Download
# archives on the host later, verifying the SHA-256 exported from those indices.
timeout 240 apt-get -o Acquire::Languages=none -o Acquire::Retries=0 -o Acquire::http::Timeout=25 -o Acquire::https::Timeout=25 -o Acquire::IndexTargets::deb-src::Sources::DefaultEnabled=false update
packages=(openssh-server sudo curl openssl zsh python3 git ca-certificates dbus-user-session squid apache2-utils docker.io)
apt-get -o APT::Get::AllowUnauthenticated=false --print-uris --download-only --reinstall install -y "${packages[@]}" > "$repo/uris.txt"
printf 'package-export-metadata\n' > /tmp/lazycat-phase
selected=()
while IFS= read -r name; do
    [[ "$name" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || exit 1
    selected+=("$name")
done < <(awk '/^\047/ {split($2,a,"_"); print a[1]}' "$repo/uris.txt" | sort -u)
[[ ${#selected[@]} -gt 0 ]]
apt-cache show "${selected[@]}" > "$repo/metadata.txt"
# Debian cloud images use mirror+file: URLs. Export only these known public
# fixture lists; never interpret arbitrary local paths from an apt URL on host.
for list in debian.list debian-security.list; do
    if [[ -f "/etc/apt/mirrors/$list" ]]; then cp "/etc/apt/mirrors/$list" "$repo/mirror-$list"; fi
done
echo 'PREPARED authenticated package metadata only; no packages installed and no product behavior verified'
