#!/usr/bin/env bash
# Is the Wi-Fi watchdog installed and triggered, and does it reach Loki? It is
# silent while the radios are healthy, so these check the mechanism, not the
# outcome. Nothing here runs the real script: with a leak present it would
# reload the radios.
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh

ROUTER=192.168.8.1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"
r() { $SSH "root@$ROUTER" "$1" 2>/dev/null; }

echo "== installed"
local_md5=$(md5 -q router/usr/local/bin/wifi-watchdog 2>/dev/null \
            || md5sum router/usr/local/bin/wifi-watchdog | cut -d' ' -f1)
[[ $(r 'test -x /usr/local/bin/wifi-watchdog && md5sum /usr/local/bin/wifi-watchdog | cut -d" " -f1') == "$local_md5" ]] \
  && pass "/usr/local/bin/wifi-watchdog is executable and matches the repo" \
  || bad "/usr/local/bin/wifi-watchdog matches the repo" "missing or differs - run scripts/deploy.sh"
[[ -n $(r 'grep -qxF /usr/local/bin/ /etc/sysupgrade.conf && echo y') ]] \
  && pass "/usr/local/bin/ kept across a firmware upgrade" \
  || bad "/usr/local/bin/ kept across a firmware upgrade" "not in /etc/sysupgrade.conf - run scripts/deploy.sh"

echo "== triggered"
[[ -n $(r "grep -F '/usr/local/bin/wifi-watchdog' /etc/crontabs/root") ]] \
  && pass "cron entry present" \
  || bad "cron entry present" "nothing in /etc/crontabs/root - run scripts/deploy.sh"
[[ $(r '/etc/init.d/cron running && echo y') == y ]] \
  && pass "crond is running" || bad "crond is running" "/etc/init.d/cron start"
# The evidence only exists while something asks the driver for its station
# list. router-metrics on lenora does, once a minute; without it a leak logs
# nothing and the watchdog never sees one.
[[ $($SSH root@192.168.8.21 'systemctl is-active homelab-router-metrics.timer' 2>/dev/null) == active ]] \
  && pass "router-metrics polls the station list from lenora (what makes a leak visible)" \
  || bad "router-metrics polls the station list" "homelab-router-metrics.timer on lenora is not active - a leak would log nothing"

echo "== reaches Loki"
# The alert matches identifier="wifi-watchdog", which exists as a label only
# once a line has arrived. Send one and look for it.
marker="verify-$(date +%s)"
r "logger -t wifi-watchdog -p daemon.notice 'verify.sh probe $marker'"
sleep 5
found=$(curl -sS --max-time 10 --cacert ../ca/rootca/certs/root.crt -G \
  'https://192.168.8.56:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={host="router", identifier="wifi-watchdog"}' \
  --data-urlencode "start=$(( ($(date +%s) - 300) * 1000000000 ))" \
  --data-urlencode 'limit=50' 2>/dev/null | grep -c "$marker" || true)
[[ "$found" != 0 ]] \
  && pass 'logged lines arrive as {host="router", identifier="wifi-watchdog"}' \
  || bad 'logged lines arrive as {host="router", identifier="wifi-watchdog"}' \
         "the marker did not reach Loki - the wifi-watchdog-acting alert would never fire"

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
