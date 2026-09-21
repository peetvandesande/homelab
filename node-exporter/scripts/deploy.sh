#!/usr/bin/env bash
# Turn on TLS for prometheus-node-exporter across the whole fleet.
#
# node-exporter is one service on eleven hosts, so it gets one directory rather
# than eleven copies of the same two files. That is the reason this does not
# follow the one-directory-per-container shape the service stacks use.
#
# ORDER MATTERS: this breaks every `node` scrape until prometheus/scripts/
# deploy.sh has run. Do both, in that order, or monitoring goes dark.
#
#   scripts/deploy.sh            the whole fleet
#   scripts/deploy.sh <ip>...    just those hosts (a new container)
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh

FLEET=(
  192.168.1.21 192.168.1.50 192.168.1.51 192.168.1.52 192.168.1.53
  192.168.1.54 192.168.1.55 192.168.1.56 192.168.1.60 192.168.1.61
  192.168.1.27
)
# deploy.sh <ip> does one host - for bringing a new container into the fleet
# without bouncing the other ten exporters.
[[ $# -gt 0 ]] && FLEET=("$@")

for ip in "${FLEET[@]}"; do
  echo "-------------------------------------------------- $ip"
  require_enrolled "$ip"
  push "$ip" root
  $SSH "root@$ip" '
    set -e
    # node-exporter runs as prometheus on every host, including lenora.
    usermod -aG tlscert prometheus
    chmod +x /etc/homelab-tls/post-renew.d/10-node-exporter
    systemctl daemon-reload
    systemctl restart prometheus-node-exporter
    for _ in $(seq 1 20); do
      systemctl is-active --quiet prometheus-node-exporter && break; sleep 1
    done
    systemctl is-active --quiet prometheus-node-exporter \
      || { journalctl -u prometheus-node-exporter --no-pager -n 20; exit 1; }
  '
  # Prove it is actually serving TLS and not just running.
  if curl -sS --max-time 8 --cacert ../ca/rootca/certs/root.crt "https://$ip:9100/metrics" -o /dev/null; then
    echo "   $ip:9100 serving TLS, verifies against the G2 root"
  else
    echo "   $ip:9100 FAILED TLS check"; exit 1
  fi
done

echo
echo "== node-exporter is now TLS everywhere"
echo "   every 'node' scrape is BROKEN until prometheus/scripts/deploy.sh runs"
