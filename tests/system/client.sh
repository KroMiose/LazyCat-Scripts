#!/usr/bin/env bash
# Run after the Linux node fixture has established CA trust.
set -euo pipefail
home=/home/fixture
mkdir -p "$home/.ssh" /root/.lazycat/ssh-ca
cp /tmp/ca /root/.lazycat/ssh-ca/lazycat-ssh-ca
cp /tmp/ca.pub /root/.lazycat/ssh-ca/lazycat-ssh-ca.pub
cp /tmp/client "$home/.ssh/lazycat_ca_ed25519"
cp /tmp/client.pub "$home/.ssh/lazycat_ca_ed25519.pub"
cp /tmp/client-cert.saved "$home/.ssh/lazycat_ca_ed25519-cert.pub"
printf 'fixture-ca,127.0.0.1 ' > "$home/.ssh/known_hosts"
cat /etc/ssh/ssh_host_ed25519_key.pub >> "$home/.ssh/known_hosts"
cat > "$home/.ssh/config" <<'CONFIG'
Host fixture-ca
    HostName 127.0.0.1
    User root
    IdentityFile ~/.ssh/lazycat_ca_ed25519
    IdentitiesOnly yes
CONFIG
cat > "$home/inventory.yaml" <<'YAML'
version: 1
ca:
  ssh_host: fixture-ca
  validity: 12h
  principals: root
hosts:
  fixture-node:
    host: 127.0.0.1
    user: root
YAML
chown -R fixture:fixture "$home/.ssh" "$home/inventory.yaml"
chmod 700 "$home/.ssh"
chmod 600 "$home/.ssh/lazycat_ca_ed25519" "$home/.ssh/config"
client() { runuser -u fixture -- env -i HOME="$home" USER=fixture PATH=/usr/bin:/bin XDG_RUNTIME_DIR="/run/user/$(id -u fixture)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u fixture)/bus" /work/lazycat-ssh "$@"; }
client source --file "$home/inventory.yaml"
fingerprint=$(ssh-keygen -lf /tmp/ca.pub | awk '{print $2}')
client trust-ca "$fingerprint"
sha256sum "$home/.ssh/lazycat_ca_ed25519" "$home/.ssh/known_hosts" > /tmp/client-preserved.sha256
client sync
client renew-status --json
sha256sum -c /tmp/client-preserved.sha256
# This observer validates the renewed cert's real acceptance on a new SSH session.
runuser -u fixture -- ssh -F "$home/.ssh/config" -o BatchMode=yes -o UpdateHostKeys=no -o HostKeyAlias=127.0.0.1 fixture-node true
sha256sum "$home/.ssh/lazycat_ca_ed25519-cert.pub" > /tmp/certificate-before-scheduled.sha256
client renew-certs --scheduled
sha256sum -c /tmp/certificate-before-scheduled.sha256
cp -p "$home/.ssh/lazycat_ca_ed25519-cert.pub" /tmp/normal-client-cert
for scenario in healthy-short invalid-interval due-short; do
    case "$scenario" in
        healthy-short) span='-1m:+100m' ;;
        invalid-interval) span='-1m:+10m' ;;
        due-short) span='-100m:+10m' ;;
    esac
    ssh-keygen -q -s /tmp/ca -I "$scenario" -n root -V "$span" /tmp/client.pub
    cat /tmp/client-cert.pub > "$home/.ssh/lazycat_ca_ed25519-cert.pub"
    sha256sum "$home/.ssh/lazycat_ca_ed25519-cert.pub" > /tmp/short-client-cert.sha256
    status=0
    client renew-certs --scheduled || status=$?
    if [[ "$scenario" == invalid-interval ]]; then
        [[ "$status" == 1 ]]
        sha256sum -c /tmp/short-client-cert.sha256
    elif [[ "$scenario" == healthy-short ]]; then
        [[ "$status" == 0 ]]
        sha256sum -c /tmp/short-client-cert.sha256
    else
        [[ "$status" == 0 ]]
        if sha256sum -c /tmp/short-client-cert.sha256; then
            echo 'Due short certificate was not renewed'; exit 1
        fi
    fi
    runuser -u fixture -- ssh -F "$home/.ssh/config" -o BatchMode=yes -o UpdateHostKeys=no -o HostKeyAlias=127.0.0.1 fixture-node true
done
cat /tmp/normal-client-cert > "$home/.ssh/lazycat_ca_ed25519-cert.pub"
sha256sum -c /tmp/client-preserved.sha256 /tmp/certificate-before-scheduled.sha256
echo 'PASS actual short-certificate lifetime: healthy no-op, invalid interval reported, due certificate renewed and new SSH accepted'
client migrate --check
client migrate --apply
# Simulate CA unavailability without breaking the already generated host config.
mv /root/.lazycat/ssh-ca/lazycat-ssh-ca /root/.lazycat/ssh-ca/unavailable
printf '\n  second-node:\n    host: 127.0.0.1\n    user: root\n' >> "$home/inventory.yaml"
if client sync; then echo 'CA failure reported complete success';exit 1;fi
grep -qx 'Host second-node' "$home/.ssh/config.d/lazycat.conf"
sha256sum -c /tmp/certificate-before-scheduled.sha256
mv /root/.lazycat/ssh-ca/unavailable /root/.lazycat/ssh-ca/lazycat-ssh-ca
client renew-certs
sha256sum -c /tmp/client-preserved.sha256
# Adopt the exact legacy systemd files while preserving interval/enabled state.
uid=$(id -u fixture)
systemctl start "user@$uid.service"
user_systemctl() { runuser -u fixture -- env -i HOME="$home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" systemctl --user "$@"; }
mkdir -p "$home/.config/systemd/user"
cat > "$home/.config/systemd/user/lazycat-ssh-renew.service" <<SERVICE
[Unit]
Description=LazyCat SSH renew certificates

[Service]
Type=oneshot
ExecStart=$home/.local/bin/lazycat-ssh renew-certs
SERVICE
cat > "$home/.config/systemd/user/lazycat-ssh-renew.timer" <<'TIMER'
[Unit]
Description=LazyCat SSH renew certificates timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=lazycat-ssh-renew.service

[Install]
WantedBy=timers.target
TIMER
chown -R fixture:fixture "$home/.config"
cp "$home/.config/systemd/user/lazycat-ssh-renew.timer" /tmp/timer-before
user_systemctl daemon-reload
rm -f "$home/.lazycat/ssh/renew-status.json"
user_systemctl enable --now lazycat-ssh-renew.timer
# OnBootSec may already be elapsed, so enabling the legacy timer can start a
# real renewal immediately. Migration correctly refuses that active old job.
# Establish its completed state explicitly, never assume enable waits for it.
deadline=$((SECONDS+180))
while true; do
    legacy_active=$(user_systemctl show lazycat-ssh-renew.service --property=ActiveState --value)
    case "$legacy_active" in
        inactive) if [[ -f "$home/.lazycat/ssh/renew-status.json" ]]; then break; fi ;;
        active|activating|deactivating) ;;
        *) echo "unexpected initial legacy task state: $legacy_active"; exit 1 ;;
    esac
    ((SECONDS<deadline)) || { echo 'initial legacy renewal did not finish'; exit 1; }
    sleep .2
done
[[ $(user_systemctl show lazycat-ssh-renew.service --property=Result --value) == success ]]
client migrate --check
client migrate --apply
cmp /tmp/timer-before "$home/.config/systemd/user/lazycat-ssh-renew.timer"
grep -q 'renew-certs --scheduled$' "$home/.config/systemd/user/lazycat-ssh-renew.service"
user_systemctl is-active lazycat-ssh-renew.timer
user_systemctl is-enabled lazycat-ssh-renew.timer
sha256sum "$home/.ssh/lazycat_ca_ed25519-cert.pub" > /tmp/cert-before-timer
rm -f "$home/.lazycat/ssh/renew-status.json"
# The preserved legacy timer has systemd's default AccuracySec=1min.
# Allow one interval plus that scheduling window and a bounded TCG margin.
deadline=$((SECONDS+180))
until [[ -f "$home/.lazycat/ssh/renew-status.json" ]] && grep -q '"scheduled":true' "$home/.lazycat/ssh/renew-status.json"; do
    ((SECONDS<deadline)) || {
        echo 'real timer did not trigger scheduled renewal'
        user_systemctl show lazycat-ssh-renew.timer lazycat-ssh-renew.service
        journalctl --no-pager "_UID=$uid" -n 100
        client renew-status --json
        exit 1
    }
    sleep 1
done
sha256sum -c /tmp/cert-before-timer
# Hold only the renewal lock, using a real running service to make the pause
# window deterministic. The product must not hold the file-operation lock here.
python3 - "$home/.lazycat/ssh/renew-lock/operation.lock" <<'PYLOCK' &
import fcntl, pathlib, sys, time
with open(sys.argv[1], 'r+') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    pathlib.Path('/tmp/renew-lock-held').touch()
    time.sleep(30)
PYLOCK
lock_holder=$!
deadline=$((SECONDS+10))
until [[ -f /tmp/renew-lock-held ]]; do ((SECONDS<deadline)) || exit 1; sleep .1; done
user_systemctl start --no-block lazycat-ssh-renew.service
deadline=$((SECONDS+10))
until [[ "$(user_systemctl show lazycat-ssh-renew.service --property=ActiveState --value)" == activating ]]; do ((SECONDS<deadline)) || exit 1; sleep .1; done
runuser -u fixture -- env -i HOME="$home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" sh -c 'echo $$ > "$HOME/native-interruption.pid"; exec /work/lazycat-ssh install-renew 19' > /tmp/native-interrupted.log 2>&1 &
interrupted_runner=$!
deadline=$((SECONDS+10))
interrupted_operation=""
while [[ -z "$interrupted_operation" ]]; do
    interrupted_operation=$(python3 - "$home/.lazycat/ssh/operations" <<'PYOP'
import json, pathlib, sys
for path in pathlib.Path(sys.argv[1]).glob('*.json'):
    op=json.loads(path.read_text())
    if op['Status']=='prepared' and op.get('Native',{}).get('Phase')=='pausing':
        print(op['ID']);break
PYOP
)
    ((SECONDS<deadline)) || { cat /tmp/native-interrupted.log;exit 1; }
    sleep .05
done
deadline=$((SECONDS+5))
until [[ "$(user_systemctl show lazycat-ssh-renew.timer --property=ActiveState --value)" == inactive ]]; do ((SECONDS<deadline)) || exit 1; sleep .05; done
kill -KILL "$(cat "$home/native-interruption.pid")"
if wait "$interrupted_runner"; then echo 'expected interrupted native command failure';exit 1;fi
kill "$lock_holder"
wait "$lock_holder" || true
deadline=$((SECONDS+15))
until [[ "$(user_systemctl show lazycat-ssh-renew.service --property=ActiveState --value)" == inactive ]]; do ((SECONDS<deadline)) || exit 1; sleep .1; done
[[ "$(user_systemctl show lazycat-ssh-renew.timer --property=ActiveState --value)" == inactive ]]
status=0
client install-renew 20 || status=$?
[[ "$status" == 3 ]]
client rollback "$interrupted_operation"
[[ "$(user_systemctl show lazycat-ssh-renew.timer --property=ActiveState --value)" == active ]]
[[ "$(user_systemctl show lazycat-ssh-renew.timer --property=UnitFileState --value)" == enabled ]]
grep -qx 'OnUnitActiveSec=1min' "$home/.config/systemd/user/lazycat-ssh-renew.timer"
sha256sum -c /tmp/cert-before-timer
echo 'PASS SIGKILL after real timer pause: durable record, blocked rerun, recovered original task, no operation-lock deadlock'
# Updating the interval must preserve independent active/enabled choices.
reset_fixture_rate_counters() {
    local unit output
    for unit in lazycat-ssh-renew.timer lazycat-ssh-renew.service; do
        if output=$(user_systemctl reset-failed "$unit" 2>&1); then
            printf 'rate-counter baseline cleared: %s\n' "$unit"
        elif [[ "$output" == "Failed to reset failed state of unit $unit: Unit $unit not loaded." ]]; then
            # systemd can garbage-collect an inactive, disabled unit between
            # commands. An unloaded object has no retained start counter.
            printf 'rate-counter baseline already absent: %s\n' "$unit"
        else
            printf '%s\n' "$output" >&2
            return 1
        fi
    done
}
minutes=2
for enabled in enabled disabled enabled-runtime; do
    for active in active inactive; do
        user_systemctl stop lazycat-ssh-renew.timer
        user_systemctl disable lazycat-ssh-renew.timer
        # Each preference combination starts with an explicit rate-counter
        # baseline. Rate exhaustion has a separate real failure scenario below.
        [[ "$(user_systemctl show lazycat-ssh-renew.service --property=ActiveState --value)" == inactive ]]
        printf 'fixture-rate-baseline\n' > /tmp/lazycat-phase
        reset_fixture_rate_counters
        printf 'go-client-lifecycle\n' > /tmp/lazycat-phase
        case "$enabled" in
            enabled) user_systemctl enable lazycat-ssh-renew.timer ;;
            enabled-runtime) user_systemctl enable --runtime lazycat-ssh-renew.timer ;;
        esac
        if [[ "$active" == active ]]; then user_systemctl start lazycat-ssh-renew.timer; fi
        previous_interval=$(sed -n 's/^OnUnitActiveSec=//p' "$home/.config/systemd/user/lazycat-ssh-renew.timer")
        operation=$(client install-renew "$minutes" | tee /tmp/timer-update.log | awk '/^Native operation:/ {print $3}')
        [[ "$(user_systemctl show lazycat-ssh-renew.timer --property=ActiveState --value)" == "$active" ]]
        [[ "$(user_systemctl show lazycat-ssh-renew.timer --property=UnitFileState --value)" == "$enabled" ]]
        grep -qx "OnUnitActiveSec=${minutes}min" "$home/.config/systemd/user/lazycat-ssh-renew.timer"
        [[ -n "$operation" ]]
        client rollback "$operation"
        grep -qx "OnUnitActiveSec=$previous_interval" "$home/.config/systemd/user/lazycat-ssh-renew.timer"
        [[ "$(user_systemctl show lazycat-ssh-renew.timer --property=ActiveState --value)" == "$active" ]]
        [[ "$(user_systemctl show lazycat-ssh-renew.timer --property=UnitFileState --value)" == "$enabled" ]]
        client install-renew "$minutes"
        minutes=$((minutes+1))
    done
done
echo 'PASS timer updates and public rollback preserve six active/enabled combinations'
# Refusing client uninstall must not disable/remove an otherwise healthy task.
user_systemctl enable lazycat-ssh-renew.timer
user_systemctl start lazycat-ssh-renew.timer
for target in "$home/.ssh/config.d/lazycat.conf" "$home/.local/bin/lazycat-ssh"; do
    cp -p "$target" /tmp/uninstall-original
    # The active renewal service can be executing this inode. Publish the
    # fixture edit by rename, just as an editor/installer would; direct writes
    # intermittently fail with ETXTBSY before the product assertion runs.
    edit_candidate=$(mktemp "${target}.fixture-edit.XXXXXX")
    cp -p "$target" "$edit_candidate"
    printf '\n# user edit\n' >> "$edit_candidate"
    mv "$edit_candidate" "$target"
    sha256sum "$target" "$home/.ssh/config" "$home/.lazycat/ssh/timer.json" "$home/.config/systemd/user/"lazycat-ssh-renew.* > /tmp/uninstall-conflict.sha256
    status=0
    client uninstall > /tmp/uninstall-conflict.log 2>&1 || status=$?
    cat /tmp/uninstall-conflict.log
    [[ "$status" == 3 ]]
    sha256sum -c /tmp/uninstall-conflict.sha256
    [[ "$(user_systemctl show lazycat-ssh-renew.timer --property=ActiveState --value)" == active ]]
    [[ "$(user_systemctl show lazycat-ssh-renew.timer --property=UnitFileState --value)" == enabled ]]
    edit_candidate=$(mktemp "${target}.fixture-restore.XXXXXX")
    cp -p /tmp/uninstall-original "$edit_candidate"
    mv "$edit_candidate" "$target"
done
echo 'PASS uninstall conflicts preserve client files and real active/enabled task'
client uninstall-renew
[[ ! -e "$home/.config/systemd/user/lazycat-ssh-renew.timer" ]]
# Declare a slow, deterministic rate-limit fixture through the disposable user
# manager, not by editing product-owned units or disabling system protection.
printf 'fixture-rate-limit-setup\n' > /tmp/lazycat-phase
rate_config=/etc/systemd/user.conf.d/90-lazycat-rate-fixture.conf
[[ ! -e "$rate_config" ]]
mkdir -p /etc/systemd/user.conf.d
printf '[Manager]\nDefaultStartLimitIntervalSec=60s\nDefaultStartLimitBurst=2\n' > "$rate_config"
systemctl restart "user@$uid.service"
mkdir -p /tmp/lazycat-rate-bin
cat > /tmp/lazycat-rate-bin/systemctl <<'RATE'
#!/bin/sh
set -eu
if [ "$*" = '--user start lazycat-ssh-renew.timer' ] && [ -f /tmp/lazycat-rate-once ]; then
    rm /tmp/lazycat-rate-once
    test "$(/usr/bin/systemctl --user show lazycat-ssh-renew.timer --property=StartLimitBurst --value)" = 2
    for attempt in 1 2 3; do
        /usr/bin/systemctl --user stop lazycat-ssh-renew.timer
        if ! /usr/bin/systemctl --user start lazycat-ssh-renew.timer; then
            /usr/bin/systemctl --user show lazycat-ssh-renew.timer --property=Result --value > /tmp/lazycat-rate-result
            exit 1
        fi
    done
    echo 'fixture failed to exhaust the real rate limit' >&2
    exit 91
fi
exec /usr/bin/systemctl "$@"
RATE
chmod 755 /tmp/lazycat-rate-bin/systemctl
touch /tmp/lazycat-rate-once
chown fixture:fixture /tmp/lazycat-rate-once
printf 'go-client-rate-limit-recovery\n' > /tmp/lazycat-phase
status=0
runuser -u fixture -- env -i HOME="$home" USER=fixture PATH=/tmp/lazycat-rate-bin:/usr/bin:/bin XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" /work/lazycat-ssh install-renew 30 > /tmp/lazycat-rate.log 2>&1 || status=$?
cat /tmp/lazycat-rate.log
[[ "$status" == 1 ]]
grep -qx start-limit-hit /tmp/lazycat-rate-result
[[ ! -e "$home/.config/systemd/user/lazycat-ssh-renew.timer" ]]
[[ ! -e "$home/.config/systemd/user/lazycat-ssh-renew.service" ]]
[[ ! -e "$home/.lazycat/ssh/timer.json" ]]
[[ "$(user_systemctl show lazycat-ssh-renew.timer --property=LoadState --value)" == not-found ]]
client doctor --json > /tmp/lazycat-rate-doctor.json
python3 - <<'RATECHECK'
import json
with open('/tmp/lazycat-rate-doctor.json') as f:
    assert json.load(f)['unfinished_native_operations']==[]
RATECHECK
sha256sum -c /tmp/cert-before-timer
rm "$rate_config"
systemctl restart "user@$uid.service"
echo 'PASS real systemd start-limit failure: original nonzero result, absent task restored, credentials preserved'
client install-renew 30
uninstall_operation=$(client uninstall | tee /tmp/full-uninstall.log | awk '/^Native operation:/ {print $3}')
[[ ! -e "$home/.config/systemd/user/lazycat-ssh-renew.timer" ]]
[[ ! -e "$home/.config/systemd/user/lazycat-ssh-renew.service" ]]
[[ ! -e "$home/.lazycat/ssh/timer.json" ]]
[[ ! -e "$home/.ssh/config.d/lazycat.conf" ]]
[[ ! -e "$home/.local/bin/lazycat-ssh" ]]
[[ "$(user_systemctl show lazycat-ssh-renew.timer --property=ActiveState --value)" == inactive ]]
[[ "$(user_systemctl show lazycat-ssh-renew.timer --property=LoadState --value)" == not-found ]]
[[ ! -L "$home/.config/systemd/user/timers.target.wants/lazycat-ssh-renew.timer" ]]
sha256sum -c /tmp/cert-before-timer
python3 - "$home" <<'PY'
import json, pathlib, sys
home=pathlib.Path(sys.argv[1])
required={str(home/p) for p in ['.local/bin/lazycat-ssh', '.ssh/config.d/lazycat.conf', '.lazycat/ssh/timer.json', '.config/systemd/user/lazycat-ssh-renew.timer', '.config/systemd/user/lazycat-ssh-renew.service']}
operations=[json.loads(p.read_text()) for p in (home/'.lazycat/ssh/operations').glob('*.json')]
assert any(o['Status']=='committed' and required <= {c['Path'] for c in o['Changes']} for o in operations), 'uninstall must record client and task files in one committed operation'
PY
echo 'PASS complete uninstall removes only owned client/task files in one transaction'
[[ -n "$uninstall_operation" ]]
client rollback "$uninstall_operation"
[[ -x "$home/.local/bin/lazycat-ssh" ]]
[[ -f "$home/.ssh/config.d/lazycat.conf" ]]
[[ "$(user_systemctl show lazycat-ssh-renew.timer --property=ActiveState --value)" == active ]]
[[ "$(user_systemctl show lazycat-ssh-renew.timer --property=UnitFileState --value)" == enabled ]]
client uninstall
echo 'PASS public uninstall rollback restores client files and real timer; repeated uninstall succeeds'
# With no login and no remaining timer, logind may already have collected the
# user record. Linger's persistent registration must still be absent.
[[ ! -e /var/lib/systemd/linger/fixture ]]
systemctl stop "user@$uid.service"
echo 'PASS real systemd legacy timer adoption, preserved interval, trigger and removal; linger untouched'
echo 'PASS Go client real CA signing, login, scheduled no-op, migration and partial sync recovery'
