#!/usr/bin/env bash
# Run only in a disposable Linux container; procd is replaced by a small shim.
set -euo pipefail
[[ -f /.dockerenv ]] || { echo 'A disposable Docker container is required.' >&2; exit 1; }
cd /work
touch /etc/openwrt_release
mkdir -p /etc/init.d /run/sshd /etc/ssh
printf '#!/bin/sh\nexit 1\n' > /usr/local/bin/opkg
chmod +x /usr/local/bin/opkg
cat > /etc/init.d/sshd <<'SERVICE'
#!/bin/sh
case "$1" in
  running) test -f /run/sshd.pid && kill -0 "$(cat /run/sshd.pid)" ;;
  enabled) test -f /tmp/sshd-enabled ;;
  enable) touch /tmp/sshd-enabled ;;
  disable) rm -f /tmp/sshd-enabled ;;
  start) test ! -f /tmp/fail-start && /usr/sbin/sshd ;;
  reload) kill -HUP "$(cat /run/sshd.pid)" ;;
  stop) if test -f /run/sshd.pid; then kill "$(cat /run/sshd.pid)"; sleep 1; fi ;;
  *) exit 1 ;;
esac
SERVICE
chmod +x /etc/init.d/sshd
printf 'Port 22\n' > /etc/ssh/sshd_config
echo 'root:container-test-only' | chpasswd
dropbear -R -p 22
ssh-keygen -q -t ed25519 -N '' -f /tmp/ca
ssh-keygen -q -t ed25519 -N '' -f /tmp/client
ssh-keygen -q -s /tmp/ca -I test -n root -V -1m:+5m /tmp/client.pub
address=$(ip -4 addr show eth0 | awk '$1 == "inet" { split($2,a,"/"); print a[1] }')
key=$(cat /tmp/ca.pub)
bash ssh/node/lazycat-ssh-node.sh install-openwrt "$key" "$address" 2222
bash ssh/node/lazycat-ssh-node.sh install-openwrt "$key" "$address" 2222
test "$(grep -c '^TrustedUserCAKeys ' /etc/ssh/sshd_config)" = 1
sshd -T | grep -x 'passwordauthentication no' > /dev/null
sshd -T | grep -x 'authorizedkeysfile none' > /dev/null
printf '[%s]:2222 ' "$address" > /tmp/known_hosts
cat /etc/ssh/ssh_host_ed25519_key.pub >> /tmp/known_hosts
ssh_opts=(-F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile=/tmp/known_hosts -o IdentitiesOnly=yes -i /tmp/client -p 2222)
ssh "${ssh_opts[@]}" "root@$address" true
mv /tmp/client-cert.pub /tmp/client-cert.saved
if ssh "${ssh_opts[@]}" "root@$address" true; then
  echo 'Unsigned key was unexpectedly accepted.' >&2; exit 1
fi
mv /tmp/client-cert.saved /tmp/client-cert.pub
cp /etc/ssh/sshd_config /tmp/expected-config
cp /etc/ssh/lazycat_ca.pub /tmp/expected-ca
/etc/init.d/sshd stop
/etc/init.d/sshd disable
touch /tmp/fail-start
if bash ssh/node/lazycat-ssh-node.sh install-openwrt "$key" "$address" 2222; then
  echo 'Failed start was not reported.' >&2; exit 1
fi
cmp /tmp/expected-config /etc/ssh/sshd_config
cmp /tmp/expected-ca /etc/ssh/lazycat_ca.pub
test ! -f /tmp/sshd-enabled
rm /tmp/fail-start
/etc/init.d/sshd start
ssh "${ssh_opts[@]}" "root@$address" true
netstat -lnt | grep ':22 '
echo 'PASS: CA login, unsigned-key rejection, repeated installation, rollback, Dropbear coexistence.'
