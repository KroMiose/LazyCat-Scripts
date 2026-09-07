#!/usr/bin/env bash
# Transfer the checked-out node script and its matching library over existing SSH.
set -euo pipefail
if [[ $# != 3 && $# != 4 ]]; then
  printf 'Usage: bash %s <ssh-host> <CA-public-key> <LAN-IPv4> [port]\n' "$0" >&2
  exit 1
fi
host="$1"
key="$2"
address="$3"
port="${4:-2222}"
[[ "$host" != -* ]] || { echo 'Invalid SSH host.' >&2; exit 1; }
ssh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

quote_sh() {
  local value
  value="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
  printf "'%s'" "$value"
}

remote='set -eu
umask 077
tmp=$(mktemp -d /tmp/lazycat-node.XXXXXX)
trap '\''rm -rf "$tmp"'\'' EXIT
tar -xzf - -C "$tmp"
bash "$tmp/node/lazycat-ssh-node.sh" install-openwrt '
remote+="$(quote_sh "$key") $(quote_sh "$address") $(quote_sh "$port")"
COPYFILE_DISABLE=1 tar --no-xattrs -czf - -C "$ssh_dir" node/lazycat-ssh-node.sh lib/common.sh |
  ssh -T "$host" "$remote"
