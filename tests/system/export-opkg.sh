#!/bin/sh
# Preparation only, in a fresh OpenWrt VM. Do not install target packages.
set -eu
test -f /etc/openwrt_release
grep -q '^option check_signature' /etc/opkg.conf
command -v usign
export_dir=/tmp/lazycat-package-export
test ! -e "$export_dir"
mkdir -p "$export_dir/feeds" "$export_dir/cache"
cp /usr/lib/opkg/status "$export_dir/status-before"
opkg update
# Keep original signed indexes, rather than generating an unsigned subset.
awk '$1 == "src/gz" || $1 == "src" {print $2 " " $3}' /etc/opkg/distfeeds.conf > "$export_dir/feeds.txt"
while read -r name url; do
    case "$name" in ''|*[!A-Za-z0-9_-]*) exit 1;; esac
    case "$url" in https://downloads.openwrt.org/*) ;; *) exit 1;; esac
    mkdir "$export_dir/feeds/$name"
    # opkg may retain compressed list bytes. Signatures authenticate the
    # uncompressed Packages document, never a reconstructed/filtered index.
    if gzip -t "/var/opkg-lists/$name" 2>/dev/null; then
        printf 'Index storage for %s: gzip\n' "$name"
        gzip -dc "/var/opkg-lists/$name" > "$export_dir/feeds/$name/Packages"
    else
        printf 'Index storage for %s: raw\n' "$name"
        cp "/var/opkg-lists/$name" "$export_dir/feeds/$name/Packages"
    fi
    wget -T 30 -O "$export_dir/feeds/$name/Packages.sig" "$url/Packages.sig"
    usign -V -P /etc/opkg/keys -m "$export_dir/feeds/$name/Packages" -x "$export_dir/feeds/$name/Packages.sig"
done < "$export_dir/feeds.txt"
opkg --download-only --cache "$export_dir/cache" install bash openssh-keygen openssh-client openssh-server
cmp /usr/lib/opkg/status "$export_dir/status-before"
find "$export_dir/cache" -type f
printf 'PASS signed opkg resolution and package downloads; target packages were not installed\n'
