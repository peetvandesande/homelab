#!/usr/bin/env bash
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.8.54

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
     'curl -sS --max-time 10 -o /dev/null https://192.168.8.53:9090/-/healthy' 2>/dev/null; then
  pass "grafana host reaches Prometheus over TLS using the system trust store"
else
  bad "grafana host reaches Prometheus over TLS using the system trust store" \
      "the G2 root is not trusted on $HOST - re-run ca/scripts/enrol.sh"
fi

if ssh -o BatchMode=yes root@$HOST 'grep -q "url: https://192.168.8.53:9090" /etc/grafana/provisioning/datasources/prometheus.yaml' 2>/dev/null; then
  pass "prometheus datasource is provisioned against https"
else bad "prometheus datasource is provisioned against https" "still http, or the file moved"; fi

echo "== loki datasource"
if ssh -o BatchMode=yes -o ConnectTimeout=5 root@$HOST \
     'curl -sS --max-time 10 -o /dev/null https://192.168.8.56:3100/ready' 2>/dev/null; then
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
if [[ "$ds" == "Loki|https://192.168.8.56:3100" ]]; then
  pass "exactly one loki datasource: Loki at https://192.168.8.56:3100"
else bad "exactly one loki datasource: Loki at https://192.168.8.56:3100" "got: ${ds:-none}"; fi

echo "== provisioned dashboards"
# Same trick: what Grafana loaded, from its own database. A JSON file the
# provider rejects is logged and skipped, so the file being on disk proves
# nothing. Grafana 13 keeps dashboards in unified storage - the `resource`
# table, one JSON document per object - not the legacy `dashboard` table,
# which stays empty.
DASHBOARD_UIDS=(homelab-dns homelab-fleet)
for uid in ${DASHBOARD_UIDS[@]+"${DASHBOARD_UIDS[@]}"}; do
  title=$(ssh -o BatchMode=yes root@$HOST 'python3 -c "
import sqlite3, json
c=sqlite3.connect(\"file:/var/lib/grafana/grafana.db?mode=ro\", uri=True)
r=c.execute(\"select value from resource where \\\"group\\\"=\x27dashboard.grafana.app\x27 and resource=\x27dashboards\x27 and name=?\", (\"'"$uid"'\",)).fetchone()
print(json.loads(r[0])[\"spec\"][\"title\"] if r else \"\")"' 2>/dev/null)
  if [[ -n "$title" ]]; then pass "dashboard '$uid' provisioned as \"$title\" (https://$HOST:3000/d/$uid)"
  else bad "dashboard '$uid' provisioned" "not in Grafana's database - journalctl -u grafana-server | grep -i provisioning"; fi
done

echo "== provisioned alert rules"
# Grafana logs a provisioning error and skips a rule file it cannot reconcile,
# so the file being on disk proves nothing - ask the API what it loaded. These
# are read-only in the UI, like the dashboards.
rules=$(curl -sS --max-time 10 --cacert ../ca/rootca/certs/root.crt \
  "https://$HOST:3000/api/v1/provisioning/alert-rules" 2>/dev/null)
if [[ -z "$rules" || "$rules" == *Unauthorized* ]]; then
  # The provisioning API needs credentials; fall back to Grafana's database,
  # which verify.sh already reads for datasources and dashboards.
  rules=$(ssh -o BatchMode=yes root@$HOST 'python3 -c "
import sqlite3
c=sqlite3.connect(\"file:/var/lib/grafana/grafana.db?mode=ro\", uri=True)
print(*[r[0] for r in c.execute(\"select uid from alert_rule\")], sep=\" \")"' 2>/dev/null)
fi
for uid in dns-component-down dnsdist-delphi-down vpn-sync-failing vpn-shunt-empty \
           rpz-feed-stale host-down disk-low systemd-unit-failed heartbeat \
           outside-probe-failing outside-vantage-down outside-cert-expiring \
           internet-unreachable tunnel-down dns-resolution-failing lab-tls-failing lab-cert-expiring; do
  if [[ "$rules" == *"$uid"* ]]; then pass "alert rule '$uid' provisioned"
  else bad "alert rule '$uid' provisioned" "not loaded - journalctl -u grafana-server | grep -i provisioning"; fi
done

# The rules carry the datasource uid, substituted at push time. If Grafana ever
# regenerates the datasource the rules would still name the old one and would
# silently never evaluate, so check they agree.
live=$(ssh -o BatchMode=yes root@$HOST 'python3 -c "
import sqlite3
c=sqlite3.connect(\"file:/var/lib/grafana/grafana.db?mode=ro\", uri=True)
r=c.execute(\"select uid from data_source where type=:t and name=:n\",
            {\"t\":\"prometheus\",\"n\":\"Prometheus\"}).fetchone()
print(r[0] if r else \"\")"' 2>/dev/null)
inrules=$(ssh -o BatchMode=yes root@$HOST \
  'grep -ho "datasourceUid: \"[A-Za-z0-9_-]*\"" /etc/grafana/provisioning/alerting/*.yaml \
   | sed "s/.*\"\(.*\)\"/\1/" | sort -u | head -1' 2>/dev/null)
if [[ -n "$live" && "$live" == "$inrules" ]]; then
  pass "alert rules point at the live Prometheus datasource ($live)"
else
  bad "alert rules point at the live Prometheus datasource" \
      "rules say '${inrules:-none}', Grafana has '${live:-none}' - re-run deploy.sh"
fi

echo "== alert delivery"
# What Grafana loaded, from its own database: the policy's default receiver is
# the home-assistant webhook. The deployed file must have its webhook id filled
# in and be readable by grafana only. Whether HA then pushes to the phone is
# not checkable from here - see CLAUDE.md, "Delivery", for the test payload.
recv=$(ssh -o BatchMode=yes root@$HOST 'python3 -c "
import sqlite3, json
c=sqlite3.connect(\"file:/var/lib/grafana/grafana.db?mode=ro\", uri=True)
r=c.execute(\"select alertmanager_configuration from alert_configuration order by id desc limit 1\").fetchone()
am=json.loads(r[0])[\"alertmanager_config\"] if r else {}
types={x[\"name\"]: [g[\"type\"] for g in x.get(\"grafana_managed_receiver_configs\", [])] for x in am.get(\"receivers\", [])}
root=am.get(\"route\", {}).get(\"receiver\", \"\")
hb=[r[\"receiver\"] for r in am.get(\"route\", {}).get(\"routes\", [])[:1]
    if [\"heartbeat\", \"=\", \"true\"] in r.get(\"object_matchers\", [])]
print(root, *types.get(root, []), \"|\", *hb, *types.get(hb[0] if hb else \"\", []))"' 2>/dev/null)
if [[ "${recv%% |*}" == "home-assistant webhook" ]]; then
  pass "notification policy delivers to the home-assistant webhook"
else bad "notification policy delivers to the home-assistant webhook" "got: ${recv:-none} - re-run deploy.sh"; fi
if [[ "${recv##*| }" == "healthchecks webhook" ]]; then
  pass "first route sends the heartbeat to the healthchecks webhook"
else bad "first route sends the heartbeat to the healthchecks webhook" "got: ${recv:-none} - re-run deploy.sh"; fi
perm=$(ssh -o BatchMode=yes root@$HOST \
  'f=/etc/grafana/provisioning/alerting/notifications.yaml; grep -q "@@" $f && echo placeholder || stat -c "%a %U:%G" $f' 2>/dev/null)
if [[ "$perm" == "640 root:grafana" ]]; then
  pass "contact points have their secrets and are 0640 root:grafana"
else bad "contact points have their secrets and are 0640 root:grafana" "got: ${perm:-none}"; fi

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
