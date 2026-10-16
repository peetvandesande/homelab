#!/usr/bin/env bash
# Install the blackbox exporter on ruby or jennie. From the clone, with sudo:
#   sudo ~/homelab/outside/install.sh
# Which server this is comes from dummy0's address. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

if ip -4 addr show dev dummy0 | grep -q "inet 192.168.254.254/"; then
  addr=192.168.254.254; self=ruby; peer=57.129.180.73
elif ip -4 addr show dev dummy0 | grep -q "inet 192.168.254.2/"; then
  addr=192.168.254.2; self=jennie; peer=145.239.73.18
else
  echo "neither ruby nor jennie: no 192.168.254.254 or .2 on dummy0"; exit 1
fi
echo "== $self, listening on $addr:9115"

apt-get install -y --no-install-recommends prometheus-blackbox-exporter >/dev/null
install -m 0644 etc/prometheus/blackbox.yml /etc/prometheus/blackbox.yml
prometheus-blackbox-exporter --config.check --config.file=/etc/prometheus/blackbox.yml

sed "s|@@ADDR@@|$addr|g" etc/default/prometheus-blackbox-exporter \
  > /etc/default/prometheus-blackbox-exporter
d=/etc/systemd/system/prometheus-blackbox-exporter.service.d
install -d "$d"
sed "s|@@ADDR@@|$addr|g" "etc/systemd/system/prometheus-blackbox-exporter.service.d/outside.conf" \
  > "$d/outside.conf"

systemctl daemon-reload
systemctl enable --quiet prometheus-blackbox-exporter
systemctl restart prometheus-blackbox-exporter

# Probe the other server once, as Prometheus will.
for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://$addr:9115/" && break; sleep 0.5
done
if curl -s "http://$addr:9115/probe?module=icmp&target=$peer" | grep -q '^probe_success 1'; then
  echo "   icmp to $peer: ok"
else
  echo "!! icmp to $peer failed - journalctl -u prometheus-blackbox-exporter"; exit 1
fi
ss -ltn "sport = :9115" | tail -n +2
