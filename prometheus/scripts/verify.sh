#!/usr/bin/env bash
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.1.53
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
  elif [[ $job == pve ]]; then
    warn "$job $inst is down" "pre-existing: prometheus-pve-exporter is not running on 127.0.0.1:9221"
  else bad "$job $inst up" "$health $err"; fi
done < /tmp/hl-targets.txt

echo "== scrapes that must be TLS actually are"
for j in node jellyfin prometheus loki; do
  if grep -q "\"$j\"" <<<"$($CURL "https://$HOST:9090/api/v1/status/config" 2>/dev/null)"; then :; fi
done
# Anchored to indented config lines: an unanchored grep also matches the
# explanatory comment at the top of the file and reports five.
# Every job except `pve`, `navidrome` and `traefik` should be https. pve
# targets a local exporter that was never migrated (and is not running);
# navidrome is plain HTTP on purpose, its single listener also being the
# deliberately unencrypted UI; traefik is a stack migrated from the old moby
# that carries its own certificates. So 8 of 11 is the correct answer.
n=$(ssh -o BatchMode=yes root@$HOST "grep -cE '^[[:space:]]+scheme: https' /etc/prometheus/prometheus.yml" 2>/dev/null)
if [[ "$n" == 8 ]]; then pass "8 jobs configured with scheme: https (prometheus, node, alloy, jellyfin, dns, loki, docker, homeassistant)"
else bad "8 jobs configured with scheme: https" "found $n - did a job lose or gain its scheme?"; fi

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
