#!/bin/sh
# Test fixture only. Preserve signed indexes; do not disable signature checks.
set -eu
test -f /etc/openwrt_release
test "$(id -u)" = 0
grep -q '^option check_signature' /etc/opkg.conf
test ! -e /etc/opkg/lazycat-original-sources
mkdir /etc/opkg/lazycat-original-sources
for source in /etc/opkg/*feeds.conf; do
    test -f "$source" || continue
    mv "$source" /etc/opkg/lazycat-original-sources/
done
: > /etc/opkg/distfeeds.conf
for feed in /opt/lazycat-offline/feeds/*; do
    test -f "$feed/Packages" && test -f "$feed/Packages.sig"
    usign -V -P /etc/opkg/keys -m "$feed/Packages" -x "$feed/Packages.sig"
    printf 'src %s file://%s\n' "${feed##*/}" "$feed" >> /etc/opkg/distfeeds.conf
done
rm -f /var/opkg-lists/*
