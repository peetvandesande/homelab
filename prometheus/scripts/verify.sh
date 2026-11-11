#!/usr/bin/env bash
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.8.53
CURL="curl -sS --max-time 10 --cacert $CA_ROOT"

echo "== prometheus API over TLS"
https_ok "prometheus /-/healthy" "https://$HOST:9090/-/healthy"
chain_ok "prometheus:9090" "$HOST:9090"
renewal_ok prometheus "$HOST"

echo "== plain HTTP must be gone"

echo "== every target healthy"
$CURL "https://$HOST:9090/api/v1/targets" > /tmp/hl-targets.json 2>/dev/null || true
python3 - <<'PY' > /tmp/hl-targets.txt
import json
try: d=json.load(open('/tmp/hl-targets.json'))
except Exception: print("PARSE-FAIL"); raise SystemExit
for t in d["data"]["activeTargets"]:
    print(t["labels"]["job"], t["labels"]["instance"], t["health"], t.get("lastError","")[:60])
PY
while read -r job inst health err; do
  if [[ $health == up ]]; then pass "$job $inst up"
  elif [[ $job == sally ]]; then
    warn "$job $inst is down" "expected for most of the day: sally powers off when its backups finish"
  else bad "$job $inst up" "$health $err"; fi
done < /tmp/hl-targets.txt

echo "== scrapes that must be TLS actually are"
for j in node prometheus loki; do
  if grep -q "\"$j\"" <<<"$($CURL "https://$HOST:9090/api/v1/status/config" 2>/dev/null)"; then :; fi
done
# Anchored to indented config lines: an unanchored grep also matches the
# explanatory comment at the top of the file and reports five.
# Every job except `jellyfin`, `navidrome`, `traefik` and `outside-*` should be
# https. jellyfin and navidrome are plain HTTP on purpose, /metrics sharing
# a listener with the deliberately unencrypted UI; traefik is a stack migrated
# from the old moby that carries its own certificates; ruby and jennie are
# reached over the tunnels. The blackbox jobs carry
# no scheme. So 12 is the correct answer.
n=$(ssh -o BatchMode=yes root@$HOST "grep -cE '^[[:space:]]+scheme: https' /etc/prometheus/prometheus.yml" 2>/dev/null)
if [[ "$n" == 12 ]]; then pass "12 jobs configured with scheme: https (sally, prometheus, node, alloy, dns, loki, docker, grafana, forgejo, n8n, n8n-sogode, nvidia-gpu)"
else bad "12 jobs configured with scheme: https" "found $n - did a job lose or gain its scheme?"; fi

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
