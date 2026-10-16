#!/usr/bin/env bash
# Prometheus (192.168.8.53): serve the API over TLS, and scrape the migrated
# services over TLS.
#
# Run this AFTER node-exporter/scripts/deploy.sh. Until it runs, every `node`
# scrape fails; after it runs, any host that is not yet TLS fails instead.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.53

# No job here has a secret: every scrape authenticates with the lab
# certificate. Home Assistant's /api/prometheus was the one exception and it
# left with the container. A future job that needs one takes the dns/ shape -
# a gitignored secrets.env sourced here, installed as a file rather than
# inlined into prometheus.yml, which is world-readable on the host.

require_enrolled "$HOST"
# The blackbox exporter (blackbox.yml). Installed before the push so the
# package's own /etc/default is overwritten by ours, not the other way round.
$SSH "root@$HOST" 'dpkg -s prometheus-blackbox-exporter >/dev/null 2>&1 \
  || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       -o Dpkg::Options::=--force-confold prometheus-blackbox-exporter >/dev/null'
push "$HOST" root
$SSH "root@$HOST" '
  set -e
  usermod -aG tlscert prometheus
  chmod +x /etc/homelab-tls/post-renew.d/20-prometheus
  promtool check config /etc/prometheus/prometheus.yml
  sysctl -q -p /etc/sysctl.d/60-ping-group-range.conf
  prometheus-blackbox-exporter --config.check --config.file=/etc/prometheus/blackbox.yml
  systemctl daemon-reload
  systemctl enable --quiet prometheus-blackbox-exporter
'
restart_assert "$HOST" prometheus-blackbox-exporter
restart_assert "$HOST" prometheus
echo "   prometheus restarted"
