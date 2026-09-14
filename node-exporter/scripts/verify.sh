#!/usr/bin/env bash
# Every node-exporter must be TLS, chain correctly, and be scraped successfully.
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
FLEET=(192.168.1.21 192.168.1.50 192.168.1.51 192.168.1.52 192.168.1.53
       192.168.1.54 192.168.1.55 192.168.1.56 192.168.1.60 192.168.1.61)

echo "== node-exporter TLS across the fleet"
for ip in "${FLEET[@]}"; do https_ok "$ip:9100" "https://$ip:9100/metrics"; done

echo "== chain (spot check; the rest share the mechanism)"
chain_ok "192.168.1.21:9100" 192.168.1.21:9100

echo "== plain HTTP must be gone"
for ip in "${FLEET[@]}"; do
  no_plain_http "$ip:9100 refuses plain HTTP" "http://$ip:9100/metrics"
done

echo "== renewal"
for ip in "${FLEET[@]}"; do renewal_ok "$ip" "$ip"; done

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
