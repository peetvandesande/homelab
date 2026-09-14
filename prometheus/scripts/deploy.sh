#!/usr/bin/env bash
# Prometheus (192.168.1.53): serve the API over TLS, and scrape the migrated
# services over TLS.
#
# Run this AFTER node-exporter/scripts/deploy.sh. Until it runs, every `node`
# scrape fails; after it runs, any host that is not yet TLS fails instead.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.1.53

require_enrolled "$HOST"
push "$HOST" root
$SSH "root@$HOST" '
  set -e
  usermod -aG tlscert prometheus
  chmod +x /etc/homelab-tls/post-renew.d/20-prometheus
  promtool check config /etc/prometheus/prometheus.yml
  systemctl daemon-reload
'
restart_assert "$HOST" prometheus
echo "   prometheus restarted"
