#!/usr/bin/env bash
# Disposable Linux container only. Real node UID; sudo's login-shell environment
# is a declared adapter. apt/curl failures are explicit, no packages are installed.
set -euo pipefail
[[ "$EUID" == 0 && "${LAZYCAT_DISPOSABLE_TEST:-}" == 1 ]]
root=${1:?source required}
mode=${2:?before or after required}
[[ "$mode" == before || "$mode" == after ]]
[[ $(getent passwd node | cut -d: -f6) == /home/node ]]
[[ ! -e /home/node/.pyenv && ! -e /home/node/.local ]]
work=$(mktemp -d);chmod 755 "$work"
trap 'result=$?; if [[ $result != 0 && -f "$work/output" ]]; then cat "$work/output"; fi; rm -rf "$work"' EXIT
mkdir -p /home/node/.pyenv/bin /home/node/.local/bin
for tool in poetry pdm uv; do
    cat > "/home/node/.local/bin/$tool" <<'TOOL'
#!/bin/sh
if [ "${1:-}" = config ]; then printf '%s\n' "$*" >> "$HOME/config-actions"; fi
printf 'existing fixture version\n'
TOOL
    chmod 755 "/home/node/.local/bin/$tool"
done
cp /home/node/.local/bin/uv /home/node/.pyenv/bin/pyenv
printf '# user shell content\n' > /home/node/.profile
chown -R node:node /home/node
cat > "$work/sudo" <<'SUDO'
#!/bin/bash
set -eu
while [[ $# -gt 0 ]]; do
    case "$1" in -i|-H) shift ;; -u) [[ "$2" == node ]];shift 2 ;; *) break ;; esac
done
exec /usr/sbin/runuser -u node -- env -i HOME=/home/node USER=node \
    PATH="$FIXTURE_BIN:/home/node/.local/bin:/home/node/.pyenv/bin:/usr/bin:/bin" \
    FICTIONAL_EXPORT_ONLY=lazycat-fake-not-a-secret "$@"
SUDO
cat > "$work/apt-get" <<'APT'
#!/bin/sh
printf 'failed apt %s\n' "$*" >> /home/node/apt-attempts
exit 17
APT
cat > "$work/curl" <<'CURL'
#!/bin/sh
printf 'failed download\n' >> /home/node/download-attempts
exit 22
CURL
chmod 755 "$work/"*
# Fail fixture preparation separately: both shim and user tool mounts must be
# executable before running either product. This caught an initial noexec setup.
if ! env FIXTURE_BIN="$work" "$work/sudo" -u node /home/node/.local/bin/uv --version; then
    echo 'fixture initialization failed: cannot execute target-user commands' >&2
    exit 90
fi
if [[ "$mode" == before ]]; then script="$root/tests/fixtures/legacy/linux/setup_python_env.sh";else script="$root/linux/setup_python_env.sh";fi
set +e
printf 'n\nn\n1\nn\n' | env -i HOME=/root SUDO_USER=node FIXTURE_BIN="$work" \
    PATH="$work:/usr/bin:/bin:/usr/sbin:/sbin" bash "$script" uv pyenv poetry pdm > "$work/output" 2>&1
status=$?
set -e
[[ "$status" == 0 ]]
if [[ "$mode" == before ]]; then
    grep -q 'declare -x FICTIONAL_EXPORT_ONLY="lazycat-fake-not-a-secret"' "$work/output"
    grep -q 'Python 开发环境配置完成' "$work/output"
    [[ -s /home/node/apt-attempts && -s /home/node/download-attempts ]]
    grep -qx 'config keyring.enabled false' /home/node/config-actions
else
    ! grep -q 'FICTIONAL_EXPORT_ONLY\|declare -x' "$work/output"
    [[ ! -e /home/node/apt-attempts && ! -e /home/node/download-attempts && ! -e /home/node/config-actions ]]
    grep -qx '# user shell content' /home/node/.profile
fi
printf 'PASS Python %s: actual entrypoint, real target UID, declared sudo-environment/apt/download adapters\n' "$mode"
