#!/usr/bin/env bash
# Actual legacy entrypoint + real yq, ssh, CA signing and new-session observer.
set -euo pipefail
home=/home/legacy-fixture
useradd -m -s /bin/bash legacy-fixture
mkdir -p "$home/.ssh" "$home/.lazycat/ssh" "$home/.local/bin" "$home/.local/share/lazycat-ssh/lib" /tmp/legacy-inventory
cp tests/fixtures/legacy-common-before.sh "$home/.local/share/lazycat-ssh/lib/common.sh"
cp /tmp/client "$home/.ssh/lazycat_ca_ed25519"
cp /tmp/client.pub "$home/.ssh/lazycat_ca_ed25519.pub"
cp /tmp/client-cert.saved "$home/.ssh/lazycat_ca_ed25519-cert.pub"
cp /home/fixture/.ssh/known_hosts "$home/.ssh/known_hosts"
cat > "$home/.ssh/config" <<'CONFIG'
Host fixture-ca
    HostName 127.0.0.1
    User root
    IdentityFile ~/.ssh/lazycat_ca_ed25519
    IdentitiesOnly yes
CONFIG
cat > /tmp/legacy-inventory/inventory.yaml <<'YAML'
version: 1
ca:
  ssh_host: fixture-ca
  principals: root
  validity: 12h
hosts: {}
YAML
printf "RAW_URL=http://127.0.0.1:18082/inventory.yaml\nGIST_URL=''\nFILE_NAME=''\n" > "$home/.lazycat/ssh/meta.env"
chown -R legacy-fixture:legacy-fixture "$home"
chmod 700 "$home/.ssh"
chmod 600 "$home/.ssh/config" "$home/.ssh/lazycat_ca_ed25519"
python3 -m http.server 18082 --bind 127.0.0.1 --directory /tmp/legacy-inventory >/tmp/legacy-http.log 2>&1 &
http_pid=$!
ca=/root/.lazycat/ssh-ca/lazycat-ssh-ca
trap 'kill "$http_pid" 2>/dev/null || true; if [[ -f "${ca}.fixture-unavailable" ]]; then mv "${ca}.fixture-unavailable" "$ca"; fi' EXIT
deadline=$((SECONDS+15))
until curl --fail --silent http://127.0.0.1:18082/inventory.yaml >/dev/null; do
    ((SECONDS<deadline)) || { echo 'legacy HTTP observer failed to start';exit 1; }
    sleep 0.1
done
legacy() { runuser -u legacy-fixture -- env -i HOME="$home" USER=legacy-fixture PATH=/work:/usr/bin:/bin bash "$home/.local/bin/lazycat-ssh" renew-certs; }
key="$home/.ssh/lazycat_ca_ed25519"
cert="${key}-cert.pub"
sha256sum "$key" "${key}.pub" "$home/.ssh/known_hosts" > /tmp/legacy-preserved.sha256
cp -p "$home/.ssh/known_hosts" /tmp/legacy-known-hosts-before
# Same actual entrypoint test on the frozen pre-fix implementation must expose
# the predictable temporary filename overwriting an unrelated existing file.
install -o legacy-fixture -g legacy-fixture -m 755 tests/fixtures/legacy-client-before.sh "$home/.local/bin/lazycat-ssh"
printf 'unrelated user file\n' > "${cert}.tmp"
chown legacy-fixture:legacy-fixture "${cert}.tmp"
old_status=0
legacy > /tmp/legacy-before.log 2>&1 || old_status=$?
cat /tmp/legacy-before.log
if [[ -e "${cert}.tmp" ]]; then echo 'known pre-fix temp clobber was not reproduced';exit 1;fi
if [[ "$old_status" != 0 ]]; then
    grep -q 'tmp_yaml: unbound variable' /tmp/legacy-before.log || { echo 'unexpected old failure';exit 1; }
fi
printf 'EXPECTED OLD DEFECT: temp clobber; command exit=%s (RETURN trap can fail after printing success)\n' "$old_status"
# Reconstruct the declared user-owned trust input for the corrected path; this
# controlled old/new comparison is not a full historical release upgrade test.
if ! cmp -s /tmp/legacy-known-hosts-before "$home/.ssh/known_hosts"; then
    echo 'OLD SIDE EFFECT: known_hosts changed during renewal'
fi
cp -p /tmp/legacy-known-hosts-before "$home/.ssh/known_hosts"
install -o legacy-fixture -g legacy-fixture -m 644 ssh/lib/common.sh "$home/.local/share/lazycat-ssh/lib/common.sh"
install -o legacy-fixture -g legacy-fixture -m 755 ssh/client/lazycat-ssh.sh "$home/.local/bin/lazycat-ssh"
chmod 750 "$home/.ssh"
chmod 400 "$key" "${key}.pub"
chmod 400 "$cert"
stat -c '%a %u %g' "$home/.ssh" "$key" "${key}.pub" "$cert" > /tmp/legacy-permissions-before
printf 'unrelated user file\n' > "${cert}.tmp"
chown legacy-fixture:legacy-fixture "${cert}.tmp"
legacy
stat -c '%a %u %g' "$home/.ssh" "$key" "${key}.pub" "$cert" > /tmp/legacy-permissions-after
cmp /tmp/legacy-permissions-before /tmp/legacy-permissions-after
cmp "${cert}.tmp" <(printf 'unrelated user file\n')
sha256sum -c /tmp/legacy-preserved.sha256
# New authentication session is the independent proof of a usable certificate.
runuser -u legacy-fixture -- ssh -F "$home/.ssh/config" -o BatchMode=yes -o UpdateHostKeys=no fixture-ca true
sha256sum "$cert" > /tmp/legacy-cert-before-failure.sha256
mv "$ca" "${ca}.fixture-unavailable"
if legacy; then echo 'legacy CA failure reported success';exit 1;fi
sha256sum -c /tmp/legacy-cert-before-failure.sha256
cmp "${cert}.tmp" <(printf 'unrelated user file\n')
mv "${ca}.fixture-unavailable" "$ca"
legacy
sha256sum -c /tmp/legacy-preserved.sha256
cmp "${cert}.tmp" <(printf 'unrelated user file\n')
runuser -u legacy-fixture -- ssh -F "$home/.ssh/config" -o BatchMode=yes -o UpdateHostKeys=no fixture-ca true
mv "${key}.pub" "${key}.pub.saved"
if legacy; then echo 'partial key pair accepted';exit 1;fi
mv "${key}.pub.saved" "${key}.pub"
sha256sum -c /tmp/legacy-preserved.sha256
mv "$cert" "${cert}.saved"
ln -s "${cert}.saved" "$cert"
sha256sum "${cert}.saved" > /tmp/legacy-cert-link-target.sha256
if legacy; then echo 'certificate symlink accepted';exit 1;fi
sha256sum -c /tmp/legacy-cert-link-target.sha256
[[ -L "$cert" ]]
rm "$cert"
mv "${cert}.saved" "$cert"
sha256sum -c /tmp/legacy-preserved.sha256
echo 'PASS actual old/new legacy entrypoint, default CA path, valid new session, failure preservation and rerun'
