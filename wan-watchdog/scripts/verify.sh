#!/usr/bin/env bash
# Is the watchdog installed, triggered and quiet? The last part matters most:
# this thing is invisible when it works, so the checks assert the mechanism
# rather than the outcome.
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh

ROUTER=192.168.8.1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"
r() { $SSH "root@$ROUTER" "$1" 2>/dev/null; }

echo "== installed"
[[ $(r 'test -x /usr/local/bin/wan-watchdog && echo y') == y ]] \
  && pass "/usr/local/bin/wan-watchdog is executable" \
  || bad "/usr/local/bin/wan-watchdog is executable" "missing - run scripts/deploy.sh"
[[ $(r 'test -x /etc/hotplug.d/kmwan/99-wan-watchdog && echo y') == y ]] \
  && pass "kmwan hotplug hook is executable" \
  || bad "kmwan hotplug hook is executable" "missing - run scripts/deploy.sh"
# Deployed copies must match this repo, which is the source of truth.
for pair in "router/usr/local/bin/wan-watchdog:/usr/local/bin/wan-watchdog" \
            "router/etc/hotplug.d/kmwan/99-wan-watchdog:/etc/hotplug.d/kmwan/99-wan-watchdog"; do
  local_md5=$(md5 -q "${pair%%:*}" 2>/dev/null || md5sum "${pair%%:*}" | cut -d' ' -f1)
  if [[ $(r "md5sum ${pair##*:} | cut -d' ' -f1") == "$local_md5" ]]; then
    pass "${pair##*:} matches the repo"
  else bad "${pair##*:} matches the repo" "differs - run scripts/deploy.sh"; fi
done

echo "== triggered"
[[ -n $(r "grep -F '/usr/local/bin/wan-watchdog' /etc/crontabs/root") ]] \
  && pass "cron entry present ($(r "grep -F '/usr/local/bin/wan-watchdog' /etc/crontabs/root" | tr -s ' ' | cut -d' ' -f1-5) )" \
  || bad "cron entry present" "nothing in /etc/crontabs/root - run scripts/deploy.sh"
[[ $(r '/etc/init.d/cron running && echo y') == y ]] \
  && pass "crond is running" || bad "crond is running" "/etc/init.d/cron start"
# The hook is useless if GL's tracker is not watching the WAN, and the tracker
# is what gives the early signal. uci, not the log, because a healthy tracker
# says nothing.
[[ $(r 'uci -q get kmwan.global.enable') == 1 && $(r 'uci -q get kmwan.wan.check') == 1 ]] \
  && pass "kmwan tracks wan ($(r 'uci -q get kmwan.wan.tracks' | tr -d "'" ) )" \
  || bad "kmwan tracks wan" "kmwan.global.enable or kmwan.wan.check is off - the hotplug hook never fires"
# Both files are outside the package set, so a sysupgrade drops them unless
# they are listed. /usr/local/bin/ covers the script.
for p in '/usr/local/bin/' '/etc/hotplug.d/kmwan/99-wan-watchdog'; do
  [[ -n $(r "grep -qxF '$p' /etc/sysupgrade.conf && echo y") ]] \
    && pass "$p kept across a firmware upgrade" \
    || bad "$p kept across a firmware upgrade" "not in /etc/sysupgrade.conf - run scripts/deploy.sh"
done

echo "== behaves"
# A sweep on a healthy line must exit 0, say nothing, and leave no state.
r 'rm -f /tmp/wan-watchdog.state'
out=$(r '/usr/local/bin/wan-watchdog 2>&1; echo "rc=$?"')
[[ "$out" == "rc=0" ]] && pass "a healthy sweep exits 0 and is silent" \
  || bad "a healthy sweep exits 0 and is silent" "$out"
[[ $(r 'test -e /tmp/wan-watchdog.state && echo y') != y ]] \
  && pass "a healthy sweep leaves no state file" \
  || bad "a healthy sweep leaves no state file" "/tmp/wan-watchdog.state exists - it only recovers, it never acted"
# The lock is what keeps the cron tick and the hotplug hook from overlapping
# during an ifup. Hold it and assert a second run declines to start.
if [[ $(r 'flock /tmp/wan-watchdog.lock -c "/usr/local/bin/wan-watchdog >/dev/null 2>&1; echo \$?"') != 0 ]]; then
  pass "a second run declines while the lock is held"
else bad "a second run declines while the lock is held" "it ran anyway - two sweeps can race an ifup"; fi

echo "== reaches Loki"
# The alert rule matches on identifier="wan-watchdog", which only exists as a
# label once a line has actually arrived, so assert the stream rather than
# trusting the tag. Send one and look for it.
marker="verify-$(date +%s)"
r "logger -t wan-watchdog -p daemon.notice 'verify.sh probe $marker'"
sleep 5
found=$(curl -sS --max-time 10 --cacert ../ca/rootca/certs/root.crt -G \
  'https://192.168.8.56:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={host="router", identifier="wan-watchdog"}' \
  --data-urlencode "start=$(( ($(date +%s) - 300) * 1000000000 ))" \
  --data-urlencode 'limit=50' 2>/dev/null | grep -c "$marker" || true)
[[ "$found" != 0 ]] \
  && pass 'logged lines arrive as {host="router", identifier="wan-watchdog"}' \
  || bad 'logged lines arrive as {host="router", identifier="wan-watchdog"}' \
         "the marker did not reach Loki - the wan-watchdog-acting alert would never fire"

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
