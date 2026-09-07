#!/usr/bin/env bash
# Full-system fixture, executed only inside the disposable QEMU guest.
set -euo pipefail
[[ -f /etc/openwrt_release || "$(hostname)" == lazycat-fixture ]] || { echo 'Fixture identity missing' >&2; exit 1; }
image="$1"
suite="$2"
exec > >(tee /tmp/lazycat-evidence.txt) 2>&1
if [[ "$image" == openwrt ]]; then
    if [[ "${3:-}" == after-reboot ]]; then
        /etc/init.d/sshd running
        /etc/init.d/sshd enabled
        /etc/init.d/dropbear running
        sha256sum -c /root/lazycat-before-reboot.sha256
        address=$(ip -4 addr show br-lan | awk '$1 == "inet" { split($2,a,"/"); print a[1] }')
        ssh -F /dev/null -p 2222 -i /root/test-keys/client -o BatchMode=yes -o IdentitiesOnly=yes -o UserKnownHostsFile=/root/test-keys/known_hosts "root@$address" true
        echo 'PASS real reboot: procd, host keys, CA trust and certificate login'
        exit 0
    fi
    test ! -x /usr/sbin/sshd
    key_dir=/root/test-keys
    mkdir -p "$key_dir"
    opkg install openssh-keygen openssh-client
    ssh-keygen -q -t ed25519 -N '' -f "$key_dir/ca"
    address=$(ip -4 addr show br-lan | awk '$1 == "inet" { split($2,a,"/"); print a[1] }')
    bash ssh/node/lazycat-ssh-node.sh install-openwrt "$(cat "$key_dir/ca.pub")" "$address" 2222
    /etc/init.d/sshd running
    /etc/init.d/sshd enabled
    /etc/init.d/dropbear running
    sshd -T | grep -x 'passwordauthentication no'
    ssh-keygen -q -t ed25519 -N '' -f "$key_dir/client"
    ssh-keygen -q -s "$key_dir/ca" -I fixture -n root -V -1m:+30m "$key_dir/client.pub"
    printf '[%s]:2222 ' "$address" > "$key_dir/known_hosts"
    cat /etc/ssh/ssh_host_ed25519_key.pub >> "$key_dir/known_hosts"
    ssh_args=(-F /dev/null -p 2222 -i "$key_dir/client" -o BatchMode=yes -o IdentitiesOnly=yes -o "UserKnownHostsFile=$key_dir/known_hosts")
    ssh "${ssh_args[@]}" "root@$address" true
    cp "$key_dir/client-cert.pub" "$key_dir/valid-cert.pub"
    rm "$key_dir/client-cert.pub"
    if ssh "${ssh_args[@]}" "root@$address" true; then echo 'Unsigned key accepted'; exit 1; fi
    ssh-keygen -q -s "$key_dir/ca" -I expired -n root -V -10m:-5m "$key_dir/client.pub"
    if ssh "${ssh_args[@]}" "root@$address" true; then echo 'Expired certificate accepted'; exit 1; fi
    ssh-keygen -q -t ed25519 -N '' -f "$key_dir/wrong-ca"
    ssh-keygen -q -s "$key_dir/wrong-ca" -I wrong -n root -V -1m:+5m "$key_dir/client.pub"
    if ssh "${ssh_args[@]}" "root@$address" true; then echo 'Wrong CA accepted'; exit 1; fi
    mv "$key_dir/valid-cert.pub" "$key_dir/client-cert.pub"
    sha256sum /etc/ssh/sshd_config /etc/ssh/ssh_host_*key /etc/dropbear/authorized_keys > /root/lazycat-before-reboot.sha256
    echo 'PASS OpenWrt procd/opkg and certificate accept/reject; reboot follows'
    exit 0
fi
[[ "$(cat /proc/1/comm)" == systemd ]]
export DEBIAN_FRONTEND=noninteractive
# Assert the dependency-under-test is absent before installing test observers.
if command -v squid >/dev/null; then echo 'Unexpected preinstalled squid'; exit 1; fi
printf 'observer-packages\n' > /tmp/lazycat-phase
# Source indexes are not needed for binary package installation. Keep this
# declared test-driver prerequisite bounded, independent of product installers.
timeout 180 apt-get -o Acquire::Languages=none -o Acquire::Retries=0 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::IndexTargets::deb-src::Sources::DefaultEnabled=false update
timeout 600 apt-get -o Acquire::Languages=none -o Acquire::Retries=0 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 install -y openssh-server sudo curl openssl zsh python3 git ca-certificates dbus-user-session
printf 'node-lifecycle\n' > /tmp/lazycat-phase
useradd -m -s /bin/bash fixture
mkdir -p /run/sshd
ssh-keygen -q -t ed25519 -N '' -f /tmp/ca
ssh-keygen -q -t ed25519 -N '' -f /tmp/client
cp /etc/ssh/sshd_config /tmp/sshd-original
bash ssh/node/lazycat-ssh-node.sh "$(cat /tmp/ca.pub)"
cp /etc/ssh/sshd_config /tmp/sshd-first
bash ssh/node/lazycat-ssh-node.sh "$(cat /tmp/ca.pub)"
cmp /tmp/sshd-first /etc/ssh/sshd_config
ssh-keygen -q -s /tmp/ca -I fixture -n root -V -1m:+30m /tmp/client.pub
printf '127.0.0.1 ' > /tmp/known_hosts
cat /etc/ssh/ssh_host_ed25519_key.pub >> /tmp/known_hosts
ssh -F /dev/null -i /tmp/client -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=/tmp/known_hosts root@127.0.0.1 true
mv /tmp/client-cert.pub /tmp/client-cert.saved
if ssh -F /dev/null -i /tmp/client -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=/tmp/known_hosts root@127.0.0.1 true; then echo 'Unsigned key accepted'; exit 1; fi
printf '1\nyes\n' | SUDO_USER=fixture bash linux/setup_sudo_nopasswd.sh
runuser -u fixture -- sudo -n true
printf '2\ny\n' | SUDO_USER=fixture bash linux/setup_sudo_nopasswd.sh
if runuser -u fixture -- sudo -n true; then echo 'sudo permission not revoked'; exit 1; fi
mkdir -p /tmp/http-fixture
printf fixture > /tmp/http-fixture/index.html
python3 -m http.server 18080 --bind 127.0.0.1 --directory /tmp/http-fixture >/tmp/http.log 2>&1 &
printf 'squid-install\n' > /tmp/lazycat-phase
printf '51938\nn\nfixture\nfixture-test-only\n' | bash linux/setup_squid_proxy.sh
printf 'squid-functional\n' > /tmp/lazycat-phase
curl --fail --max-time 15 --noproxy '' --proxy http://127.0.0.1:51938 --proxy-user fixture:fixture-test-only http://127.0.0.1:18080 >/dev/null
code=$(curl --max-time 15 --noproxy '' --proxy http://127.0.0.1:51938 -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080)
[[ "$code" == 407 ]]
sha256sum /etc/squid/passwd > /tmp/passwd-before
# Existing credentials must survive an ordinary rerun.
printf '51938\n' | bash linux/setup_squid_proxy.sh
sha256sum -c /tmp/passwd-before
systemctl is-active squid
if [[ "$suite" == upstream ]]; then
    test ! -d /home/fixture/.nvm
    test ! -e /home/fixture/.local/bin/uv
    printf '2\n22.20.0\nn\nn\n' | runuser -u fixture -- env -i HOME=/home/fixture USER=fixture PATH=/usr/bin:/bin SHELL=/bin/bash bash common/setup_node_env.sh
    runuser -u fixture -- env -i HOME=/home/fixture PATH=/usr/bin:/bin bash common/setup_node_env.sh --check
    runuser -u fixture -- env -i HOME=/home/fixture PATH=/usr/bin:/bin bash -c 'source "$HOME/.nvm/nvm.sh"; node -p "2+2"' | grep -x 4
    runuser -u fixture -- env -i HOME=/home/fixture USER=fixture PATH=/usr/bin:/bin bash linux/setup_python_env.sh uv
    runuser -u fixture -- env -i HOME=/home/fixture PATH=/usr/bin:/bin bash linux/setup_python_env.sh uv
    runuser -u fixture -- env -i HOME=/home/fixture PATH=/home/fixture/.local/bin:/usr/bin:/bin uv venv /home/fixture/test-project/.venv
    runuser -u fixture -- /home/fixture/test-project/.venv/bin/python -c 'assert 2+2 == 4'
    echo 'PASS live nvm/Node/uv installation and interpreter behavior'
fi
if [[ "$suite" == docker ]]; then bash tests/system/docker.sh;fi
printf 'go-client-lifecycle\n' > /tmp/lazycat-phase
bash tests/system/client.sh
printf 'legacy-client-lifecycle\n' > /tmp/lazycat-phase
bash tests/system/legacy-client.sh
echo 'PASS full-system SSH login/rejection, sudo grant/revoke, Squid auth/credential preservation'
