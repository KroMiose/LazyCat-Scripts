#!/usr/bin/env bash
# Actual daemon stop/restart; inject only the first reported restart failure.
set -euo pipefail
[[ $(hostname) == lazycat-fixture && $EUID == 0 ]] || exit 90
work=$(mktemp -d /tmp/docker-recovery.XXXXXX)
target=/etc/systemd/system/docker.service.d/http-proxy.conf
chmod 640 "$target"
python3 - "$target" <<'PY'
import os,sys
os.setxattr(sys.argv[1],'user.lazycat-docker',b'original preference')
PY
cp --preserve=mode,ownership,timestamps,xattr "$target" "$work/before"
cat > "$work/inject.sh" <<'BASH'
systemctl() {
    if [[ "${1:-}" == restart && "${2:-}" == docker && ! -f "$DOCKER_FAULT/injected" ]]; then
        touch "$DOCKER_FAULT/injected"
        command systemctl stop docker || return 74
        if [[ "$DOCKER_FAULT_KIND" == metadata ]]; then
            python3 - <<'PY'
import os
os.setxattr('/etc/systemd/system/docker.service.d/http-proxy.conf','user.lazycat-docker',b'operator edit after publication')
PY
        fi
        return 73
    fi
    command systemctl "$@"
}
BASH
reset_fixture() {
    local staged
    staged=$(mktemp "${target}.fixture.XXXXXX")
    cp --preserve=mode,ownership,timestamps,xattr "$work/before" "$staged"
    mv "$staged" "$target"
    systemctl daemon-reload
    # Each old/new case declares a fresh start budget. Previous lifecycle
    # restarts must not exhaust Ubuntu's StartLimitBurst before fault injection.
    # This is fixture preparation only; product recovery never clears limits.
    systemctl reset-failed docker.service docker.socket
    systemctl restart docker
    docker info >/dev/null
    rm -f "$work/injected"
}
for kind in plain metadata; do
    for implementation in old new; do
        reset_fixture
        program=linux/setup_docker_proxy.sh
        [[ "$implementation" != old ]] || program=tests/fixtures/docker-recovery-before.sh
        status=0
        DOCKER_FAULT="$work" DOCKER_FAULT_KIND="$kind" BASH_ENV="$work/inject.sh" bash "$program" set --url http://127.0.0.1:18081 --restart > "$work/$kind-$implementation.log" 2>&1 || status=$?
        cat "$work/$kind-$implementation.log"
        [[ -f "$work/injected" ]]
        if [[ "$implementation" == old ]]; then
            [[ "$status" == 1 ]]
            cmp "$work/before" "$target"
            python3 - "$target" <<'PY'
import os,sys
assert 'user.lazycat-docker' not in os.listxattr(sys.argv[1])
PY
            echo "EXPECTED OLD DEFECT: Docker $kind failure recovery loses native xattrs, including subsequent operator preferences"
        elif [[ "$kind" == plain ]]; then
            [[ "$status" == 1 ]]
            cmp "$work/before" "$target"
            [[ $(stat -c %a "$target") == 640 ]]
            python3 - "$target" <<'PY'
import os,sys
assert os.getxattr(sys.argv[1],'user.lazycat-docker')==b'original preference'
PY
            docker info >/dev/null
        else
            [[ "$status" == 3 ]]
            grep -F 'HTTP_PROXY=http://127.0.0.1:18081' "$target"
            python3 - "$target" <<'PY'
import os,sys
assert os.getxattr(sys.argv[1],'user.lazycat-docker')==b'operator edit after publication'
PY
            if systemctl is-active --quiet docker; then echo 'conflict unexpectedly restarted Docker';exit 1;fi
            grep -qx recovery-conflict "${target}".lazycat-operation.*/status
        fi
    done
done
# Explicit fixture reconciliation for later scenes; not product recovery.
reset_fixture
limit=/etc/systemd/system/docker.service.d/lazycat-fixture-start-limit.conf
cat > "$limit" <<'UNIT'
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=1
UNIT
systemctl daemon-reload
systemctl stop docker.service docker.socket
systemctl reset-failed docker.service docker.socket
systemctl start docker.service
docker info >/dev/null
# Some systemd versions reset the consumed start budget on daemon-reload.
# Exhaust it at the actual restart boundary, on both apply and recovery,
# using real service restarts rather than assuming earlier starts still count.
cat > "$work/start-limit-inject.sh" <<'BASH'
systemctl() {
    if [[ "${1:-}" == restart && "${2:-}" == docker ]]; then
        command systemctl show docker.service -p StartLimitIntervalUSec -p StartLimitBurst
        [[ $(command systemctl show docker.service -p StartLimitBurst --value) == 1 ]] || return 91
        local attempt result
        for attempt in 1 2 3; do
            result=0
            command systemctl restart docker || result=$?
            if [[ "$result" != 0 ]]; then
                [[ $(command systemctl show docker.service -p Result --value) == start-limit-hit ]] || return 91
                printf 'Observed real start-limit-hit at restart attempt %s\n' "$attempt"
                return "$result"
            fi
        done
        echo 'fixture failed to exhaust the real Docker start budget' >&2
        return 91
    fi
    command systemctl "$@"
}
BASH
status=0
BASH_ENV="$work/start-limit-inject.sh" bash linux/setup_docker_proxy.sh set --url http://127.0.0.1:18081 --restart > "$work/start-limit.log" 2>&1 || status=$?
cat "$work/start-limit.log"
[[ "$status" == 1 ]]
cmp "$work/before" "$target"
[[ $(systemctl show docker.service -p Result --value) == start-limit-hit ]]
grep -F '旧配置服务恢复失败' "$work/start-limit.log"
[[ $(grep -c 'Observed real start-limit-hit' "$work/start-limit.log") == 2 ]]
if systemctl is-active --quiet docker; then echo 'start limit unexpectedly bypassed';exit 1;fi
python3 - "$target" <<'PY'
import os,sys
assert os.getxattr(sys.argv[1],'user.lazycat-docker')==b'original preference'
PY
echo 'PASS real Docker start limit: original failure retained, config restored, unavailable service reported'
# Explicit reconciliation of the deliberately exhausted test service.
rm "$limit"
reset_fixture
echo 'PASS real Docker failure recovery preserves attrs; later metadata edits stop recovery and service changes'
