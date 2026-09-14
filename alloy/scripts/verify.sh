#!/usr/bin/env bash
# Every host must serve Alloy's metrics over TLS, be scraped, and have logged
# something to Loki recently.
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
LOKI=192.168.1.56
CURL="curl -sS --max-time 10 --cacert $CA_ROOT"
FLEET=(192.168.1.21 192.168.1.50 192.168.1.51 192.168.1.52 192.168.1.53
       192.168.1.54 192.168.1.55 192.168.1.56 192.168.1.60 192.168.1.61)

echo "== alloy TLS across the fleet"
for ip in "${FLEET[@]}"; do https_ok "$ip:12345" "https://$ip:12345/-/ready"; done

echo "== chain (spot check; the rest share the mechanism)"
chain_ok "192.168.1.21:12345" 192.168.1.21:12345

echo "== plain HTTP must be gone"
for ip in "${FLEET[@]}"; do
  no_plain_http "$ip:12345 refuses plain HTTP" "http://$ip:12345/-/ready"
done

echo "== every host has shipped lines in the last hour"
# Asked of Loki rather than of Alloy: an Alloy that is up but cannot read the
# journal (missing group) reports healthy and ships nothing.
hosts=$($CURL -G "https://$LOKI:3100/loki/api/v1/query" \
          --data-urlencode 'query=sum by (host) (count_over_time({host=~".+"}[1h]))' 2>/dev/null \
        | python3 -c 'import json,sys
for r in json.load(sys.stdin)["data"]["result"]: print(r["metric"]["host"], r["value"][1])' 2>/dev/null)
for ip in "${FLEET[@]}"; do
  name=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$ip" hostname 2>/dev/null)
  [[ -z "$name" ]] && { bad "$ip ships logs" "cannot ssh to learn its hostname"; continue; }
  n=$(awk -v h="$name" '$1==h {print $2}' <<<"$hosts")
  if [[ -n "$n" && "$n" -gt 0 ]]; then pass "$ip ($name) shipped $n lines in the last hour"
  else bad "$ip ($name) ships logs" "no lines with host=\"$name\" in the last hour"; fi
done

echo "== scraped by prometheus"
read -r n down < <($CURL "https://192.168.1.53:9090/api/v1/targets" 2>/dev/null \
  | python3 -c '
import json,sys
ts=[t for t in json.load(sys.stdin)["data"]["activeTargets"] if t["labels"]["job"]=="alloy"]
down=[t["labels"]["instance"] for t in ts if t["health"]!="up"]
print(len(ts), " ".join(down))' 2>/dev/null)
if [[ "${n:-0}" -eq ${#FLEET[@]} && -z "${down:-}" ]]; then pass "prometheus alloy job: all $n targets up"
else bad "prometheus alloy job: all ${#FLEET[@]} targets up" "targets=${n:-0} down='${down:-}' - deploy prometheus/ or wait a scrape interval"; fi

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
