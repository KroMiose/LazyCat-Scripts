#!/usr/bin/env bash
# Only inside the disposable guest; actual account, SSH daemon and CLI observers.
set -euo pipefail
[[ "$(hostname)" == lazycat-fixture && "$(id -u)" == 0 ]]
[[ "$(getent passwd fixture | cut -d: -f6)" == /home/fixture ]]
usermod -p '*' fixture
ssh-keygen -q -t ed25519 -N '' -f /tmp/access-client
install -d -o fixture -g fixture -m 700 /home/fixture/.ssh
{ printf '# administrator authorization preferences\n# disabled reference: '; cat /tmp/access-client.pub; } > /tmp/access-original
install -o fixture -g fixture -m 640 /tmp/access-original /home/fixture/.ssh/authorized_keys
sha256sum /tmp/access-client /tmp/access-client.pub > /tmp/access-key.sha256
connection=(ssh -F /dev/null -i /tmp/access-client -o CertificateFile=none -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=/tmp/known_hosts fixture@127.0.0.1)
if "${connection[@]}" true; then echo 'unregistered key accepted';exit 1;fi
runuser -u fixture -- bash common/setup_ssh_access.sh --public-key /tmp/access-client.pub > /tmp/access-install.log
cat /tmp/access-install.log
if grep -q 'PRIVATE KEY' /tmp/access-install.log; then echo 'private key appeared in ordinary registration';exit 1;fi
[[ "$("${connection[@]}" id -un)" == fixture ]]
sha256sum /home/fixture/.ssh/authorized_keys > /tmp/access-first.sha256
runuser -u fixture -- bash common/setup_ssh_access.sh --public-key /tmp/access-client.pub
sha256sum -c /tmp/access-first.sha256
operations=(/home/fixture/.ssh/authorized_keys.lazycat-operation.*)
[[ ${#operations[@]} == 1 ]]
runuser -u fixture -- bash common/lazycat-check.sh rollback "${operations[0]}"
cmp /tmp/access-original /home/fixture/.ssh/authorized_keys
[[ "$(stat -c '%a %U %G' /home/fixture/.ssh/authorized_keys)" == '640 fixture fixture' ]]
if "${connection[@]}" true; then echo 'rolled-back key retained access';exit 1;fi
# A pre-existing forced-command restriction must not be weakened by re-registering
# the same public key. The SSH observer actually receives the forced response.
{ printf 'restrict,command="printf restricted" '; cat /tmp/access-client.pub; } > /tmp/access-restricted
install -o fixture -g fixture -m 640 /tmp/access-restricted /home/fixture/.ssh/authorized_keys
runuser -u fixture -- bash common/setup_ssh_access.sh --public-key /tmp/access-client.pub
cmp /tmp/access-restricted /home/fixture/.ssh/authorized_keys
[[ "$("${connection[@]}" id -un)" == restricted ]]
sha256sum -c /tmp/access-key.sha256
# Preserve this lifecycle's logs/backups, restore only its own initial resource.
install -o fixture -g fixture -m 640 /tmp/access-original /home/fixture/.ssh/authorized_keys
if "${connection[@]}" true; then echo 'fixture teardown retained authorization';exit 1;fi
echo 'PASS public-key registration, actual login, no-op repeat, rollback rejection and forced-command preservation'
