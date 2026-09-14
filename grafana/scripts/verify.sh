#!/usr/bin/env bash
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.1.54

echo "== grafana UI over TLS"
https_ok "grafana /api/health" "https://$HOST:3000/api/health"
chain_ok "grafana:3000" "$HOST:3000"
renewal_ok grafana "$HOST"

echo "== plain HTTP must be gone"
no_plain_http "3000 refuses plain HTTP" "http://$HOST:3000/api/health"

echo "== grafana's host trusts the lab CA"
# Asks the question that matters without needing Grafana credentials: from
# grafana's own container, does a plain curl - system trust store only, no
# --cacert - reach Prometheus over TLS? If yes, Grafana's datasource can too,
# because that is the same store Grafana uses.
if ssh -o BatchMode=yes -o ConnectTimeout=5 root@$HOST \
     'curl -sS --max-time 10 -o /dev/null https://192.168.1.53:9090/-/healthy' 2>/dev/null; then
  pass "grafana host reaches Prometheus over TLS using the system trust store"
else
  bad "grafana host reaches Prometheus over TLS using the system trust store" \
      "the G2 root is not trusted on $HOST - re-run ca/scripts/enrol.sh"
fi

if ssh -o BatchMode=yes root@$HOST 'grep -q "url: https://192.168.1.53:9090" /etc/grafana/provisioning/datasources/prometheus.yaml' 2>/dev/null; then
  pass "datasource is provisioned against https"
else bad "datasource is provisioned against https" "still http, or the file moved"; fi

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
