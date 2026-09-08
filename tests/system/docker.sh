#!/usr/bin/env bash
# Only called inside a disposable Linux system guest by guest.sh.
set -euo pipefail
printf 'observer-packages\n' > /tmp/lazycat-phase
timeout 600 apt-get -o Acquire::Retries=0 -o Acquire::http::Timeout=20 install -y docker.io
printf 'docker-lifecycle\n' > /tmp/lazycat-phase
systemctl start docker
deadline=$((SECONDS+60))
until docker info >/dev/null 2>&1; do ((SECONDS<deadline)) || exit 1;sleep 1;done
# Exercise effective group permissions in a newly started process.
bash linux/setup_docker_nopasswd.sh add --user fixture
runuser -u fixture -- docker info >/dev/null
sha256sum /etc/group > /tmp/docker-group-first
bash linux/setup_docker_nopasswd.sh add --user fixture
sha256sum -c /tmp/docker-group-first
bash linux/setup_docker_nopasswd.sh remove --user fixture
if runuser -u fixture -- docker info >/dev/null 2>&1; then echo 'removed user retained Docker access in a new process';exit 1;fi
# The fixture trust root is scoped to the fictional registry inside this guest.
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/docker-registry.key -out /tmp/docker-registry.crt -days 1 -subj /CN=registry.fixture.invalid -addext subjectAltName=DNS:registry.fixture.invalid >/tmp/docker-cert.log 2>&1
mkdir -p /etc/docker/certs.d/registry.fixture.invalid
cp /tmp/docker-registry.crt /etc/docker/certs.d/registry.fixture.invalid/ca.crt
# A localhost proxy records real daemon traffic; its TLS registry has no layers.
python3 /work/tests/system/docker_proxy.py >/tmp/docker-proxy.log 2>&1 &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null || true' EXIT
deadline=$((SECONDS+15))
until [[ -f /tmp/docker-proxy-ready ]]; do ((SECONDS<deadline)) || exit 1;sleep 1;done
before=$(systemctl show docker --property=MainPID --value)
bash linux/setup_docker_proxy.sh set --url http://127.0.0.1:18081 --no-proxy localhost,127.0.0.1
[[ "$(systemctl show docker --property=MainPID --value)" == "$before" ]]
# An ordinary repeat preserves the file and does not restart the daemon.
bash linux/setup_docker_proxy.sh set --url http://127.0.0.1:18081 --no-proxy localhost,127.0.0.1
[[ "$(systemctl show docker --property=MainPID --value)" == "$before" ]]
# Explicit restart applies the already-saved pending file, even if its bytes are unchanged.
bash linux/setup_docker_proxy.sh set --url http://127.0.0.1:18081 --no-proxy localhost,127.0.0.1 --restart
systemctl show docker --property=Environment --value | grep -F 'HTTP_PROXY=http://127.0.0.1:18081'
if timeout 30 docker pull registry.fixture.invalid/test/image:fixture; then echo 'fixture rejected all registry requests but pull succeeded';exit 1;fi
grep -F 'registry.fixture.invalid' /tmp/docker-proxy-requests
# Now permit a tunnel exclusively to the loopback TLS fixture registry.
touch /tmp/docker-proxy-allow
timeout 60 docker pull registry.fixture.invalid/test/image:fixture
docker image inspect registry.fixture.invalid/test/image:fixture --format '{{.Os}}/{{.Architecture}} {{index .Config.Labels "lazycat.fixture"}}' | grep -x 'linux/amd64 verified'
grep -F '/v2/test/image/blobs/' /tmp/docker-registry-requests
docker image rm registry.fixture.invalid/test/image:fixture
bash linux/setup_docker_proxy.sh remove --restart
docker info >/dev/null
if systemctl show docker --property=Environment --value | grep -q 'HTTP_PROXY=';then echo 'proxy remained after removal';exit 1;fi
echo 'PASS actual Docker daemon proxy request, denied and successful fixture pull, explicit restart, removal and group permission lifecycle'

bash tests/system/docker-recovery.sh
