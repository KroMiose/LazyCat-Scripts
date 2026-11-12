#!/usr/bin/env bash
# Real root entrypoint, only inside a disposable container/VM. No network needed.
set -euo pipefail
[[ "$EUID" == 0 ]]
root=${1:?source snapshot required}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
for implementation in before after; do
    home="$scratch/$implementation"
    mkdir -p "$home/cache/lib" "$home/bin"
    if [[ "$implementation" == before ]]; then
        cp "$root/tests/fixtures/legacy-client-before.sh" "$home/bin/client"
    else
        cp "$root/ssh/client/lazycat-ssh.sh" "$home/bin/client"
    fi
    cat > "$home/cache/lib/common.sh" <<'LIB'
printf 'cache executed as %s\n' "$EUID" > "$HOME/executed"
exit 91
LIB
    set +e
    env -i HOME="$home" PATH=/usr/bin:/bin LAZYCAT_SSH_HOME="$home/cache" \
        bash "$home/bin/client" sync > "$home/output" 2>&1
    status=$?
    set -e
    if [[ "$implementation" == before ]]; then
        [[ "$status" == 91 ]]
        grep -qx 'cache executed as 0' "$home/executed"
    else
        [[ "$status" == 1 && ! -e "$home/executed" ]]
        grep -q '请不要使用 sudo' "$home/output"
        [[ ! -e "$home/.ssh" && ! -e "$home/.lazycat" ]]
    fi
done
printf 'PASS real root bootstrap refuses user cache before execution\n'
for implementation in before after; do
    home="$scratch/node-$implementation"
    mkdir -p "$home/.nvm"
    cat > "$home/.nvm/nvm.sh" <<'NVM'
printf 'nvm executed as %s\n' "$EUID" > "$HOME/executed"
exit 91
NVM
    if [[ "$implementation" == before ]]; then
        script="$root/tests/fixtures/legacy-node-check-before.sh"
    else
        script="$root/common/setup_node_env.sh"
    fi
    set +e
    env -i HOME="$home" PATH=/usr/bin:/bin bash "$script" --check > "$home/output" 2>&1
    status=$?
    set -e
    if [[ "$implementation" == before ]]; then
        [[ "$status" == 91 ]]
        grep -qx 'nvm executed as 0' "$home/executed"
    else
        [[ "$status" == 1 && ! -e "$home/executed" ]]
        grep -q '不应以 root' "$home/output"
    fi
done
printf 'PASS real root Node check refuses user nvm code before sourcing\n'
