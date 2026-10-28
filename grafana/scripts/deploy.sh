#!/usr/bin/env bash
# Grafana (192.168.8.54): serve the UI over TLS and reach Prometheus over TLS.
#
# Run this AFTER prometheus/scripts/deploy.sh - the datasource pushed here
# points at https, so doing it first leaves every dashboard broken in between.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.54
SECRETS=../../homelab-private/grafana/secrets.env
RESPONDER_SECRETS=../../homelab-private/responder/secrets.env
[[ -f $SECRETS ]] || { echo "$SECRETS missing - see CLAUDE.md, Alerting"; exit 1; }
# shellcheck disable=SC1090
source "$SECRETS"
[[ -n "${HA_WEBHOOK_ID:-}" ]] || { echo "HA_WEBHOOK_ID unset in $SECRETS"; exit 1; }
[[ "${HEALTHCHECKS_PING_URL:-}" == https://hc-ping.com/* ]] \
  || { echo "HEALTHCHECKS_PING_URL unset or not an hc-ping.com URL in $SECRETS"; exit 1; }
[[ -f $RESPONDER_SECRETS ]] || { echo "$RESPONDER_SECRETS missing - run responder/scripts/deploy.sh first"; exit 1; }
RESPONDER_TOKEN=$(sed -n 's/^RESPONDER_TOKEN=//p' "$RESPONDER_SECRETS")
[[ -n "$RESPONDER_TOKEN" ]] || { echo "RESPONDER_TOKEN unset in $RESPONDER_SECRETS"; exit 1; }

require_enrolled "$HOST"
push "$HOST" root

# The contact points carry secrets, so push() has just installed it with its
# placeholder; overwrite it with the substituted copy, readable by grafana only.
# Substituted here and sent over stdin, so neither appears in a remote command
# line.
NOTIFY=etc/grafana/provisioning/alerting/notifications.yaml
sed -e "s|@@HA_WEBHOOK_ID@@|${HA_WEBHOOK_ID}|g" \
    -e "s|@@HEALTHCHECKS_PING_URL@@|${HEALTHCHECKS_PING_URL}|g" \
    -e "s|@@RESPONDER_TOKEN@@|${RESPONDER_TOKEN}|g" "root/$NOTIFY" | $SSH "root@$HOST" "
  cat > '/$NOTIFY.deploytmp' && chown root:grafana '/$NOTIFY.deploytmp' \
  && chmod 0640 '/$NOTIFY.deploytmp' && mv -f '/$NOTIFY.deploytmp' '/$NOTIFY'"
echo "   $NOTIFY (0640 root:grafana, HA webhook id, ping URL and responder token substituted)"

# Alert rules need the datasource's uid, and neither provisioned datasource has
# one pinned - invariant 4 says why one must never be added to a live
# datasource. So the uids Grafana generated are read back out of its own
# database and substituted into the pushed rules, the same way homelab/dns
# substitutes secrets at push time. A rebuilt Grafana therefore needs no edit
# here; verify.sh asserts the substituted values still match.
# Most rules query Prometheus; wifi-sta-table-stale queries Loki, because the
# fault it watches has no metric.
$SSH "root@$HOST" '
  set -e
  dsuid() { python3 -c "
import sqlite3, sys
c=sqlite3.connect(\"file:/var/lib/grafana/grafana.db?mode=ro\", uri=True)
r=c.execute(\"select uid from data_source where type=:t and name=:n\",
            {\"t\":sys.argv[1],\"n\":sys.argv[2]}).fetchone()
print(r[0] if r else \"\")" "$1" "$2"; }
  uid=$(dsuid prometheus Prometheus)
  loki_uid=$(dsuid loki Loki)
  if [ -z "$uid" ] || [ -z "$loki_uid" ]; then
    echo "!! no provisioned Prometheus/Loki datasource yet - alert rules will not load."
    echo "   This is expected on a first install: deploy once more once Grafana"
    echo "   has created it."
  else
    for f in /etc/grafana/provisioning/alerting/*.yaml; do
      sed -i -e "s|@@PROM_DS_UID@@|$uid|g" -e "s|@@LOKI_DS_UID@@|$loki_uid|g" "$f"
    done
    echo "   alert rules bound to Prometheus datasource $uid, Loki $loki_uid"
  fi
  usermod -aG tlscert grafana
  chmod +x /etc/homelab-tls/post-renew.d/20-grafana
  systemctl daemon-reload
'
restart_assert "$HOST" grafana-server

# restart_assert is not enough here. A provisioning error (a datasource file
# Grafana cannot reconcile) makes it exit after a few seconds and
# Restart=on-failure brings it straight back, so is-active flickers true while
# the UI is in fact down. Only a 200 from the API means it came up.
for _ in $(seq 1 24); do
  curl -sS --max-time 5 --cacert ../ca/rootca/certs/root.crt -o /dev/null -f \
    "https://$HOST:3000/api/health" 2>/dev/null && { echo "   grafana restarted and serving"; exit 0; }
  sleep 5
done
echo "!! grafana is not serving after 2 minutes - crash-looping? check:"
$SSH "root@$HOST" 'systemctl show grafana-server -p NRestarts; journalctl -u grafana-server --no-pager -n 200 -o cat | grep -i "provisioning error" | tail -2'
exit 1
