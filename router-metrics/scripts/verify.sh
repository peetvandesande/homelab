#!/usr/bin/env bash
# Is lenora collecting from the router and the ONT, and do the readings look
# like a working line? Asks Prometheus, so it also proves the scrape.
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh

q() { # q <promql> -> first value, or empty
  ssh -o BatchMode=yes root@192.168.8.53 \
    "curl -sS --max-time 10 --cacert /etc/homelab-tls/root_ca.crt -G https://192.168.8.53:9090/api/v1/query \
     --data-urlencode 'query=$1'" 2>/dev/null \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "")'
}

echo "== collection"
age=$(q 'time() - homelab_router_metrics_timestamp_seconds')
if [[ -n "$age" ]] && python3 -c "import sys; sys.exit(0 if float('$age') < 180 else 1)"; then
  pass "router.prom written ${age%.*} s ago, and scraped"
else bad "router.prom fresh and scraped" "age '${age:-none}' - systemctl status homelab-router-metrics on lenora"; fi
[[ $(q homelab_router_metrics_up) == 1 ]] && pass "lenora reaches the router" \
  || bad "lenora reaches the router" "its key on the router - rerun scripts/deploy.sh"
[[ $(q homelab_ont_up) == 1 ]] && pass "the router reaches the ONT" \
  || bad "the router reaches the ONT" "dbclient -T on the router, or the key on the stick - rerun scripts/deploy.sh"

echo "== the line"
[[ $(q homelab_ont_ploam_state) == 51 ]] && pass "PLOAM state 51 (O5.1)" \
  || bad "PLOAM state 51 (O5.1)" "got '$(q homelab_ont_ploam_state)' - router/ORANGE.md"
rx=$(q homelab_ont_rx_power_dbm)
if [[ -n "$rx" ]] && python3 -c "import sys; sys.exit(0 if -21 < float('$rx') < -8 else 1)"; then
  pass "Rx power $rx dBm"
else bad "Rx power between -21 and -8 dBm" "got '${rx:-none}'"; fi
[[ $(q homelab_router_ipv6_prefix_delegated) == 1 ]] && pass "IPv6 prefix delegated" \
  || bad "IPv6 prefix delegated" "router/ORANGE.md, 'The IAID trap'"

echo "== wi-fi"
n=$(q 'sum(homelab_router_wifi_clients)')
[[ -n "$n" && "$n" != 0 ]] && pass "$n Wi-Fi client links" || bad "Wi-Fi clients reported" "got '${n:-none}'"

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
