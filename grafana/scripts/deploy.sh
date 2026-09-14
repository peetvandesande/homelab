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
echo "   grafana restarted"
