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
user_systemctl enable --now lazycat-ssh-renew.timer
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
minutes=2
for enabled in enabled disabled enabled-runtime; do
    for active in active inactive; do
        user_systemctl stop lazycat-ssh-renew.timer
        user_systemctl disable lazycat-ssh-renew.timer
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
    printf '\n# user edit\n' >> "$target"
    sha256sum "$target" "$home/.ssh/config" "$home/.lazycat/ssh/timer.json" "$home/.config/systemd/user/"lazycat-ssh-renew.* > /tmp/uninstall-conflict.sha256
    status=0
    client uninstall > /tmp/uninstall-conflict.log 2>&1 || status=$?
    cat /tmp/uninstall-conflict.log
    [[ "$status" == 3 ]]
    sha256sum -c /tmp/uninstall-conflict.sha256
    [[ "$(user_systemctl show lazycat-ssh-renew.timer --property=ActiveState --value)" == active ]]
    [[ "$(user_systemctl show lazycat-ssh-renew.timer --property=UnitFileState --value)" == enabled ]]
    cp -p /tmp/uninstall-original "$target"
done
echo 'PASS uninstall conflicts preserve client files and real active/enabled task'
client uninstall-renew
[[ ! -e "$home/.config/systemd/user/lazycat-ssh-renew.timer" ]]
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
