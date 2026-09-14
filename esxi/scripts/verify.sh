#!/usr/bin/env bash
# esther's logs and SMART must be arriving in Loki, over TLS, via the relay.
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
RELAY=192.168.1.56
CURL="curl -sS --max-time 10 --cacert $CA_ROOT"

count() { # count <logql selector> <range>
  $CURL -G "https://$RELAY:3100/loki/api/v1/query" \
    --data-urlencode "query=sum(count_over_time($1[$2]))" 2>/dev/null \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)' 2>/dev/null || echo 0
}

echo "== relay listener"
chain_ok "$RELAY:1514 (syslog/TLS)" "$RELAY:1514"

echo "== esther syslog arriving"
n=$(count '{host="esther", job="esxi-syslog"}' 1h)
if [[ "$n" -gt 0 ]]; then pass "esther shipped $n syslog lines in the last hour"
else bad "esther ships syslog" "no lines with host=\"esther\" in the last hour - run scripts/configure-host.sh, or check vmsyslogd on esther"; fi

echo "== SMART arriving"
if ssh -o BatchMode=yes root@$RELAY 'systemctl is-enabled --quiet esxi-smart.timer' 2>/dev/null; then
  pass "esxi-smart.timer enabled on the relay"
else bad "esxi-smart.timer enabled on the relay" "not enabled - run scripts/deploy.sh"; fi
n=$(count '{host="esther", job="esxi-smart"}' 2h)
if [[ "$n" -gt 0 ]]; then
  pass "SMART for $n device line(s) in the last two hours"
  echo "        latest:"
  $CURL -G "https://$RELAY:3100/loki/api/v1/query_range" \
    --data-urlencode 'query={host="esther", job="esxi-smart"}' --data-urlencode 'limit=10' 2>/dev/null \
    | python3 -c 'import json,sys
for s in json.load(sys.stdin)["data"]["result"]:
    print("        ", s["stream"]["device"][:40], s["values"][0][1][:110])' 2>/dev/null
else
  bad "SMART lines in the last two hours" "none - systemctl start esxi-smart on $RELAY and read its journal"
fi
n=$(count '{host="esther", job="esxi-smart"} |= "below_threshold"' 24h)
[[ "$n" -gt 0 ]] && warn "a SMART attribute is at or below its threshold" "query {host=\"esther\", job=\"esxi-smart\"} |= \"below_threshold\""

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
