#!/usr/bin/env bash
# Real Squid parser/daemon and actual installer entrypoints. Only the parser's
# input-open failure, one restart return, and display-only IP lookup are injected.
set -euo pipefail
work=$(mktemp -d /tmp/squid-fault.XXXXXX)
cp -p /etc/squid/squid.conf "$work/config.before"
cp -p /etc/squid/passwd "$work/passwd.before"
sha256sum /etc/squid/squid.conf /etc/squid/passwd > "$work/before.sha256"
stat -c '%a %u %g' /etc/squid/squid.conf /etc/squid/passwd > "$work/before.stat"
mkdir "$work/bin"
cat > "$work/bin/curl" <<'SH'
#!/bin/sh
case "$*" in
 *https://api.ipify.org*|*https://ifconfig.me*|*https://icanhazip.com*) printf '127.0.0.1\n' ;;
 *) exec /usr/bin/curl "$@" ;;
esac
SH
cat > "$work/bin/squid" <<'SH'
#!/bin/sh
exec /usr/sbin/squid -k parse -f /dev/null/lazycat.conf
SH
chmod 755 "$work/bin/"*
# Verify the fault really comes from Squid, without relying on a fabricated log.
parser_status=0
"$work/bin/squid" > "$work/parser.log" 2>&1 || parser_status=$?
cat "$work/parser.log"
[[ "$parser_status" != 0 ]]
if grep -q ERROR "$work/parser.log"; then echo 'parser fixture does not exhibit the declared FATAL-only failure';exit 1;fi
# Original entrypoint loses this nonzero parser status and reports success.
printf '51938\nn\nrotated\nnew-fixture-only\n' | PATH="$work/bin:/usr/sbin:/usr/bin:/sbin:/bin" bash tests/fixtures/legacy/linux/setup_squid_proxy.sh > "$work/old.log" 2>&1
cat "$work/old.log"
grep -q '配置语法验证通过' "$work/old.log"
echo 'EXPECTED OLD DEFECT: actual Squid parser failed but original entrypoint reported success'
# Reconstruct the declared starting state; this is a controlled old/new proof,
# not a claim that the original installer recovered its own changes.
cp -p "$work/config.before" /etc/squid/squid.conf
cp -p "$work/passwd.before" /etc/squid/passwd
systemctl restart squid
observer() {
    local deadline=$((SECONDS+15))
    until ss -H -ltn 'sport = :51938' | grep -q .; do
        ((SECONDS<deadline)) || { journalctl --no-pager -u squid -n 40; return 1; }
        sleep .1
    done
    /usr/bin/curl --fail --max-time 15 --noproxy '' --proxy http://127.0.0.1:51938 --proxy-user fixture:fixture-test-only http://127.0.0.1:18080 >/dev/null
}
observer
# Hold a real independent flock across actual installer invocations. The
# registered historical script ignores it; the new entrypoint must fail before
# dependency installation, prompting, candidate creation or service changes.
exec 8>>/run/lazycat-squid.lock
flock -n 8
printf '51938\n' | bash tests/fixtures/squid-port-before.sh
echo 'EXPECTED OLD DEFECT: existing Squid operation lock ignored'
find /etc/squid -maxdepth 1 -name '.lazycat-operation.*' -print | sort > "$work/operations.before"
pid=$(systemctl show squid --property=MainPID --value)
status=0
printf '51938\n' | bash linux/setup_squid_proxy.sh > "$work/concurrent.log" 2>&1 || status=$?
cat "$work/concurrent.log"
[[ "$status" == 3 ]]
find /etc/squid -maxdepth 1 -name '.lazycat-operation.*' -print | sort > "$work/operations.after"
cmp "$work/operations.before" "$work/operations.after"
sha256sum -c "$work/before.sha256"
[[ "$(systemctl show squid --property=MainPID --value)" == "$pid" ]]
flock -u 8
exec 8>&-
printf '51938\n' | bash linux/setup_squid_proxy.sh
observer
echo 'PASS real Squid lock excludes contenders before side effects and permits retry after release'
status=0
printf '51938\nn\nrotated\nnew-fixture-only\n' | PATH="$work/bin:/usr/sbin:/usr/bin:/sbin:/bin" bash linux/setup_squid_proxy.sh --rotate-credentials > "$work/new-parse.log" 2>&1 || status=$?
cat "$work/new-parse.log"
[[ "$status" != 0 ]]
sha256sum -c "$work/before.sha256"
observer
# Exercise failure AFTER both candidate files have been committed and the real
# daemon has stopped. The restoration restart uses the real service manager.
rm "$work/bin/squid"
printf 'pending\n' > "$work/fail-restart"
cat > "$work/bin/systemctl" <<'SH'
#!/bin/sh
if [ "$1" = restart ] && [ "$2" = squid ] && [ -f "$SQUID_FAULT/fail-restart" ]; then
    mv "$SQUID_FAULT/fail-restart" "$SQUID_FAULT/restart-injected"
    /usr/bin/systemctl stop squid || exit 74
    exit 73
fi
exec /usr/bin/systemctl "$@"
SH
chmod 755 "$work/bin/systemctl"
status=0
printf '51938\nn\nrotated\nnew-fixture-only\n' | SQUID_FAULT="$work" PATH="$work/bin:/usr/sbin:/usr/bin:/sbin:/bin" bash linux/setup_squid_proxy.sh --rotate-credentials > "$work/new-restart.log" 2>&1 || status=$?
cat "$work/new-restart.log"
[[ "$status" != 0 && -f "$work/restart-injected" ]]
sha256sum -c "$work/before.sha256"
stat -c '%a %u %g' /etc/squid/squid.conf /etc/squid/passwd > "$work/after.stat"
cmp "$work/before.stat" "$work/after.stat"
systemctl is-active --quiet squid
systemctl is-enabled --quiet squid
observer
code=$(/usr/bin/curl --max-time 15 --noproxy '' --proxy http://127.0.0.1:51938 --proxy-user rotated:new-fixture-only -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080)
[[ "$code" == 407 ]]
# A readiness timeout after a successful restart must restore the old port and
# credentials too. The observer below uses the real ss and makes one HTTP request.
cat > "$work/bin/ss" <<'SH'
#!/bin/sh
exit 0
SH
chmod 755 "$work/bin/ss"
status=0
printf '51939\nn\nrotated\nnew-fixture-only\n' | SQUID_FAULT="$work" PATH="$work/bin:/usr/sbin:/usr/bin:/sbin:/bin" bash linux/setup_squid_proxy.sh --rotate-credentials > "$work/new-readiness.log" 2>&1 || status=$?
cat "$work/new-readiness.log"
[[ "$status" != 0 ]]
grep -q 'Squid 未在限定时间内监听端口' "$work/new-readiness.log"
sha256sum -c "$work/before.sha256"
observer
[[ -z "$(ss -H -ltn 'sport = :51939')" ]]
rm "$work/bin/ss"
pid=$(systemctl show squid --property=MainPID --value)
printf '51938\n' | bash linux/setup_squid_proxy.sh
[[ "$(systemctl show squid --property=MainPID --value)" == "$pid" ]]
sha256sum -c "$work/before.sha256"
observer
echo 'PASS real Squid parser old/new proof, two-file restart recovery, preserved auth/modes/service, and no-restart rerun'

# An ordinary blank answer retains a nondefault listener and old credentials.
printf '51940\n' | bash linux/setup_squid_proxy.sh
printf '\n' | bash tests/fixtures/squid-port-before.sh
grep -qx 'http_port 51938' /etc/squid/squid.conf
observer
echo 'EXPECTED OLD DEFECT: blank rerun reset existing Squid port from 51940 to 51938'
printf '51940\n' | bash linux/setup_squid_proxy.sh
pid=$(systemctl show squid --property=MainPID --value)
sha256sum /etc/squid/squid.conf /etc/squid/passwd > "$work/nondefault.sha256"
printf '\n' | bash linux/setup_squid_proxy.sh
sha256sum -c "$work/nondefault.sha256"
[[ "$(systemctl show squid --property=MainPID --value)" == "$pid" ]]
/usr/bin/curl --fail --max-time 15 --noproxy '' --proxy http://127.0.0.1:51940 --proxy-user fixture:fixture-test-only http://127.0.0.1:18080 >/dev/null
# Return this lifecycle to its original port for later guest observations.
printf '51938\n' | bash linux/setup_squid_proxy.sh
observer
echo 'PASS existing nondefault Squid port and credentials survive blank/default rerun without restart'

# An administrator edits while the real interactive prompt is being read.
# Only read is wrapped; parsing, files and the daemon remain real.
cat > "$work/prompt-edit.sh" <<'SH'
read() {
    if [[ ! -f "$SQUID_FAULT/prompt-edited" ]]; then
        printf '# concurrent administrator preference\n' >> /etc/squid/squid.conf
        python3 -c 'import os; os.setxattr("/etc/squid/squid.conf", "user.lazycat-fixture", b"administrator")'
        touch "$SQUID_FAULT/prompt-edited"
    fi
    builtin read "$@"
}
SH
printf '51938\n' | SQUID_FAULT="$work" BASH_ENV="$work/prompt-edit.sh" bash tests/fixtures/squid-port-before.sh
if grep -q 'concurrent administrator preference' /etc/squid/squid.conf; then
    echo 'Historical input did not reproduce overwritten administrator edit'; exit 1
fi
echo 'EXPECTED OLD DEFECT: prompt-time administrator edit overwritten'
cp --preserve=mode,ownership,timestamps,xattr "$work/config.before" /etc/squid/squid.conf
systemctl restart squid
observer
rm "$work/prompt-edited"
pid=$(systemctl show squid --property=MainPID --value)
status=0
printf '51938\n' | SQUID_FAULT="$work" BASH_ENV="$work/prompt-edit.sh" bash linux/setup_squid_proxy.sh > "$work/prompt-conflict.log" 2>&1 || status=$?
cat "$work/prompt-conflict.log"
[[ "$status" == 3 ]]
grep -qx '# concurrent administrator preference' /etc/squid/squid.conf
python3 -c 'import os; assert os.getxattr("/etc/squid/squid.conf", "user.lazycat-fixture") == b"administrator"'
cmp "$work/passwd.before" /etc/squid/passwd
[[ "$(systemctl show squid --property=MainPID --value)" == "$pid" ]]
observer
# Construct the next declared input explicitly, then verify ordinary updates
# preserve an existing native extended attribute and nondefault file mode.
cp --preserve=mode,ownership,timestamps,xattr "$work/config.before" /etc/squid/squid.conf
chmod 640 /etc/squid/squid.conf
python3 -c 'import os; os.setxattr("/etc/squid/squid.conf", "user.lazycat-fixture", b"original")'
printf '51940\n' | bash linux/setup_squid_proxy.sh
[[ "$(stat -c %a /etc/squid/squid.conf)" == 640 ]]
python3 -c 'import os; assert os.getxattr("/etc/squid/squid.conf", "user.lazycat-fixture") == b"original"'
/usr/bin/curl --fail --max-time 15 --noproxy '' --proxy http://127.0.0.1:51940 --proxy-user fixture:fixture-test-only http://127.0.0.1:18080 >/dev/null
printf '51938\n' | bash linux/setup_squid_proxy.sh
observer
echo 'PASS administrator edit conflict, unchanged credentials/service and native attribute preservation'
