#!/usr/bin/env bash
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.1.56
CURL="curl -sS --max-time 10 --cacert $CA_ROOT"

echo "== loki API over TLS"
# /ready is 503 for up to a minute after a restart while the ingester settles
# in the ring; the process is fine. Give it that long before calling it down.
for _ in $(seq 12); do
  $CURL -o /dev/null -w '%{http_code}' "https://$HOST:3100/ready" 2>/dev/null | grep -q '^200$' && break
  sleep 5
done
https_ok "loki /ready" "https://$HOST:3100/ready"
https_ok "loki /metrics" "https://$HOST:3100/metrics"
chain_ok "loki:3100" "$HOST:3100"
renewal_ok loki "$HOST"

echo "== plain HTTP must be gone"
no_plain_http "3100 refuses plain HTTP" "http://$HOST:3100/ready"

echo "== ingest and query round-trip"
# Push one line, then ask for it back. Proves the write path, the store and the
# query path in one go - /ready alone passes on a Loki that can accept nothing.
now=$(date +%s%N)
if $CURL -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
     -X POST "https://$HOST:3100/loki/api/v1/push" \
     -d "{\"streams\":[{\"stream\":{\"job\":\"verify\",\"host\":\"workstation\"},\"values\":[[\"$now\",\"verify.sh round-trip $now\"]]}]}" \
     2>/dev/null | grep -q '^204$'; then
  pass "push accepted (204)"
else bad "push accepted (204)" "push did not return 204"; fi
sleep 1
if $CURL -G "https://$HOST:3100/loki/api/v1/query_range" \
     --data-urlencode 'query={job="verify"}' --data-urlencode "start=$((now-60000000000))" \
     2>/dev/null | grep -q "round-trip $now"; then
  pass "query returns the pushed line"
else bad "query returns the pushed line" "line not found within 60s window"; fi

echo "== scraped by prometheus"
$CURL "https://192.168.1.53:9090/api/v1/targets" 2>/dev/null \
  | python3 -c '
import json,sys
d=json.load(sys.stdin)
ok=[t for t in d["data"]["activeTargets"] if t["labels"]["job"]=="loki" and t["health"]=="up"]
sys.exit(0 if ok else 1)' \
  && pass "prometheus loki job is up" \
  || bad "prometheus loki job is up" "no healthy target - deploy prometheus/ or wait a scrape interval"

echo "== grafana's host trusts loki"
# Same question grafana/scripts/verify.sh asks about Prometheus: plain curl,
# system trust store only, from grafana's own container.
if ssh -o BatchMode=yes -o ConnectTimeout=5 root@192.168.1.54 \
     "curl -sS --max-time 10 -o /dev/null https://$HOST:3100/ready" 2>/dev/null; then
  pass "grafana host reaches Loki over TLS using the system trust store"
else
  bad "grafana host reaches Loki over TLS using the system trust store" \
      "the G2 root is not trusted on .54, or loki is down"
fi

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
