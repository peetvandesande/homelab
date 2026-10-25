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

if ssh -o BatchMode=yes root@$HOST 'grep -q "url: https://prometheus.home:9090" /etc/grafana/provisioning/datasources/prometheus.yaml' 2>/dev/null; then
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
if [[ "$ds" == "Loki|https://loki.home:3100" ]]; then
  pass "exactly one loki datasource: Loki at https://loki.home:3100"
else bad "exactly one loki datasource: Loki at https://loki.home:3100" "got: ${ds:-none}"; fi

echo "== provisioned dashboards"
# Same trick: what Grafana loaded, from its own database. A JSON file the
# provider rejects is logged and skipped, so the file being on disk proves
# nothing. Grafana 13 keeps dashboards in unified storage - the `resource`
# table, one JSON document per object - not the legacy `dashboard` table,
# which stays empty.
DASHBOARD_UIDS=(homelab-dns homelab-fleet homelab-router)
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
# Normalise either source to one uid per line: the API answers JSON, the
# database fallback a space-separated list. The match below is then exact, which
# matters - a substring match passes 'disk-low' on 'ha-vm-disk-low' alone, and
# 'memory-low' on 'ha-vm-memory-low'.
if [[ "$rules" == *'"uid"'* ]]; then
  rule_uids=$(grep -oE '"uid"[[:space:]]*:[[:space:]]*"[A-Za-z0-9_-]+"' <<<"$rules" \
              | sed 's/.*"\([A-Za-z0-9_-]*\)"$/\1/')
else
  rule_uids=$(tr ' ' '\n' <<<"$rules" | sed '/^$/d')
fi

# One group per line, in the order of the files in
# root/etc/grafana/provisioning/alerting/. A rule missing from this list is not
# checked at all, which is how four of them went unasserted until October 2026
# - the coverage check below now keeps the list honest.
RULE_UIDS=(
  # homelab.yaml, group dns
  alerting-evaluation-failing dns-component-down dnsdist-delphi-down
  dnsdist-dropping-clients dnsdist-vpn-resolver-down recursor-servfail-high
  rpz-feed-failing rpz-feed-stale vpn-shunt-empty vpn-shunt-pool-empty
  vpn-sync-failing vpn-sync-stale
  # homelab.yaml, group fleet
  disk-low host-down mailcow-container-down memory-low service-target-down
  systemd-unit-failed textfile-collector-error
  # apt.yaml
  apt-not-patching apt-reboot-required apt-security-pending
  apt-services-need-restart
  # heartbeat.yaml
  heartbeat
  # homeassistant-vm.yaml
  ha-vm-agent-down ha-vm-disk-low ha-vm-down ha-vm-memory-low ha-vm-metrics-stale
  # outside.yaml
  outside-cert-expiring outside-probe-failing outside-vantage-down
  # probes.yaml
  dns-resolution-failing internet-unreachable lab-cert-expiring lab-tls-failing
  tunnel-down
  # router.yaml
  ipv6-prefix-missing ont-downstream-sync-lost ont-hot ont-not-operational
  ont-rx-power-low ont-unreachable router-metrics-stale wan-receiving-nothing
  wan-watchdog-acting wifi-sta-table-stale
)
for uid in ${RULE_UIDS[@]+"${RULE_UIDS[@]}"}; do
  if grep -qxF "$uid" <<<"$rule_uids"; then pass "alert rule '$uid' provisioned"
  else bad "alert rule '$uid' provisioned" "not loaded - journalctl -u grafana-server | grep -i provisioning"; fi
done

# RULE_UIDS is hand-maintained, so assert it covers every rule in the
# provisioned files - otherwise adding a rule and forgetting the list leaves it
# unchecked and a later provisioning error silently drops it. notifications.yaml
# is excluded: its uids are contact points, not rules.
infiles=$(ssh -o BatchMode=yes root@$HOST '
  for f in /etc/grafana/provisioning/alerting/*.yaml; do
    [ "${f##*/}" = notifications.yaml ] && continue
    sed -n "s/^      - uid: *//p" "$f"
  done | sort -u' 2>/dev/null)
uncovered=$(comm -23 <(echo "$infiles") <(printf '%s\n' "${RULE_UIDS[@]}" | sort -u))
if [[ -z "$uncovered" ]]; then
  pass "RULE_UIDS covers every rule in the provisioned files (${#RULE_UIDS[@]} rules)"
else
  bad "RULE_UIDS covers every rule in the provisioned files" \
      "not listed: $(tr '\n' ' ' <<<"$uncovered")- add them to RULE_UIDS in verify.sh"
fi

# The rules carry the datasource uid, substituted at push time. If Grafana ever
# regenerates a datasource the rules would still name the old one and would
# silently never evaluate, so check they agree. Two datasources are substituted
# now - Prometheus for almost everything, Loki for wifi-sta-table-stale - so
# each is checked by name rather than by taking the first uid in the files.
inrules=$(ssh -o BatchMode=yes root@$HOST \
  'grep -ho "datasourceUid: \"[A-Za-z0-9_-]*\"" /etc/grafana/provisioning/alerting/*.yaml \
   | sed "s/.*\"\(.*\)\"/\1/" | sort -u' 2>/dev/null)
for ds in prometheus:Prometheus loki:Loki; do
  live=$(ssh -o BatchMode=yes root@$HOST 'python3 -c "
import sqlite3, sys
c=sqlite3.connect(\"file:/var/lib/grafana/grafana.db?mode=ro\", uri=True)
r=c.execute(\"select uid from data_source where type=:t and name=:n\",
            {\"t\":sys.argv[1],\"n\":sys.argv[2]}).fetchone()
print(r[0] if r else \"\")" '"${ds%%:*} ${ds##*:}" 2>/dev/null)
  if [[ -n "$live" ]] && grep -qxF "$live" <<<"$inrules"; then
    pass "alert rules point at the live ${ds##*:} datasource ($live)"
  else
    bad "alert rules point at the live ${ds##*:} datasource" \
        "Grafana has '${live:-none}', not among the rules' uids - re-run deploy.sh"
  fi
done

# A placeholder left unsubstituted is the failure mode both of the above would
# miss on a first install: the rule loads, names a uid that does not exist and
# never evaluates.
# The two reachability curls below keep IP literals deliberately: they ask
# whether grafana's container can reach the backend over TLS using the system
# trust store, and an IP keeps DNS out of that question. The datasource URLs
# themselves are names - asserted separately, just below each.
if ssh -o BatchMode=yes root@$HOST \
     'grep -l "@@[A-Z_]*_DS_UID@@" /etc/grafana/provisioning/alerting/*.yaml' >/dev/null 2>&1; then
  bad "no unsubstituted datasource placeholders" "a rule still carries @@..._DS_UID@@ - re-run deploy.sh"
else
  pass "no unsubstituted datasource placeholders"
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
