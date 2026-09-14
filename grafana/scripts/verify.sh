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
  pass "prometheus datasource is provisioned against https"
else bad "prometheus datasource is provisioned against https" "still http, or the file moved"; fi

echo "== loki datasource"
if ssh -o BatchMode=yes -o ConnectTimeout=5 root@$HOST \
     'curl -sS --max-time 10 -o /dev/null https://192.168.1.56:3100/ready' 2>/dev/null; then
  pass "grafana host reaches Loki over TLS using the system trust store"
else
  bad "grafana host reaches Loki over TLS using the system trust store" \
      "the G2 root is not trusted on $HOST, or loki is down"
fi

# What Grafana actually loaded, read from its own database rather than the
# provisioning file: exactly one loki datasource at the https URL, and no
# hand-made stragglers (a provisioned datasource is read-only in the UI, and
# "add data source" there creates an empty second one instead).
ds=$(ssh -o BatchMode=yes root@$HOST 'python3 -c "
import sqlite3
c=sqlite3.connect(\"file:/var/lib/grafana/grafana.db?mode=ro\", uri=True)
print(*[\"%s|%s\" % r for r in c.execute(\"select name,url from data_source where type=\x27loki\x27\")], sep=\"\n\")"' 2>/dev/null)
if [[ "$ds" == "Loki|https://192.168.1.56:3100" ]]; then
  pass "exactly one loki datasource: Loki at https://192.168.1.56:3100"
else bad "exactly one loki datasource: Loki at https://192.168.1.56:3100" "got: ${ds:-none}"; fi

echo "== provisioned dashboards"
# Same trick: what Grafana loaded, from its own database. A JSON file the
# provider rejects is logged and skipped, so the file being on disk proves
# nothing. Grafana 13 keeps dashboards in unified storage - the `resource`
# table, one JSON document per object - not the legacy `dashboard` table,
# which stays empty.
for uid in esxi; do
  title=$(ssh -o BatchMode=yes root@$HOST 'python3 -c "
import sqlite3, json
c=sqlite3.connect(\"file:/var/lib/grafana/grafana.db?mode=ro\", uri=True)
r=c.execute(\"select value from resource where \\\"group\\\"=\x27dashboard.grafana.app\x27 and resource=\x27dashboards\x27 and name=?\", (\"'"$uid"'\",)).fetchone()
print(json.loads(r[0])[\"spec\"][\"title\"] if r else \"\")"' 2>/dev/null)
  if [[ -n "$title" ]]; then pass "dashboard '$uid' provisioned as \"$title\" (https://$HOST:3000/d/$uid)"
  else bad "dashboard '$uid' provisioned" "not in Grafana's database - journalctl -u grafana-server | grep -i provisioning"; fi
done

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
