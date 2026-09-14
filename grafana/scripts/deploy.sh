#!/usr/bin/env bash
# Grafana (192.168.1.54): serve the UI over TLS and reach Prometheus over TLS.
#
# Run this AFTER prometheus/scripts/deploy.sh - the datasource pushed here
# points at https, so doing it first leaves every dashboard broken in between.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.1.54

require_enrolled "$HOST"
push "$HOST" root
$SSH "root@$HOST" '
  set -e
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
