#!/usr/bin/env bash
# Fixture setup only: replace guest package sources with the verified local repo.
set -euo pipefail
[[ "$(hostname)" == lazycat-fixture && "$(id -u)" == 0 && -f /opt/lazycat-offline/Packages ]]
mkdir /etc/apt/lazycat-original-sources
mv /etc/apt/sources.list.d /etc/apt/lazycat-original-sources/sources.list.d
mkdir /etc/apt/sources.list.d
if [[ -f /etc/apt/sources.list ]]; then mv /etc/apt/sources.list /etc/apt/lazycat-original-sources/main.list;fi
printf '%s\n' 'deb [trusted=yes] file:/opt/lazycat-offline ./' > /etc/apt/sources.list
# Clear downloaded live indices so apt cannot resolve an unrecorded package.
rm -f /var/lib/apt/lists/*InRelease /var/lib/apt/lists/*Release /var/lib/apt/lists/*Packages*
