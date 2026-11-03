#!/usr/bin/env bash
# Ship ruby's or jennie's journal to Loki at home. From the server's clone:
#   cd ~/homelab && git pull && sudo alloy/scripts/install-outside.sh
# Which server this is comes from dummy0's address. Safe to re-run. Proves
# lines with this host's label are landing in Loki before it reports success.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

if ip -4 addr show dev dummy0 | grep -q "inet 192.168.254.254/"; then
  host=ruby
elif ip -4 addr show dev dummy0 | grep -q "inet 192.168.254.2/"; then
  host=jennie
else
  echo "neither ruby nor jennie: no 192.168.254.254 or .2 on dummy0"; exit 1
fi
echo "== $host"

# Same pin as the lab fleet (ALLOY_VER in deploy.sh); bump the two together.
ALLOY_VER="1.19.2"
LOKI=https://loki.home:3100
ROOT_CA=/etc/alloy/homelab-root-g2.crt
export DEBIAN_FRONTEND=noninteractive

echo "== loki reachable over the tunnel"
install -d -m 0755 /etc/alloy
install -m 0644 ../ca/rootca/certs/root.crt "$ROOT_CA"
curl -sS --max-time 10 --cacert "$ROOT_CA" -o /dev/null -f "$LOKI/ready" \
  || { echo "!! $LOKI/ready did not answer 200 - check the tunnel home, DNS for loki.home, and that loki is up"; exit 1; }
echo "   $LOKI ready, verified against the lab root"

echo "== alloy $ALLOY_VER"
if [ ! -s /etc/apt/keyrings/grafana.gpg ]; then
  apt-get install -y -qq curl ca-certificates gnupg >/dev/null
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main' \
    > /etc/apt/sources.list.d/grafana.list
fi
if dpkg -s alloy 2>/dev/null | grep -q "^Version: ${ALLOY_VER}-"; then
  echo "   already installed"
else
  apt-get update -qq
  apt-get install -y -qq --allow-downgrades "alloy=${ALLOY_VER}-1" >/dev/null
  echo "   installed"
fi
apt-mark hold alloy >/dev/null

echo "== config"
sed "s|@@HOST@@|$host|g" outside/etc/alloy/config.alloy > /etc/alloy/config.alloy.tmp
chown root:alloy /etc/alloy/config.alloy.tmp && chmod 0640 /etc/alloy/config.alloy.tmp
mv -f /etc/alloy/config.alloy.tmp /etc/alloy/config.alloy
install -m 0644 outside/etc/default/alloy /etc/default/alloy
install -d -m 0755 /etc/systemd/system/alloy.service.d
install -m 0644 outside/etc/systemd/system/alloy.service.d/outside.conf \
  /etc/systemd/system/alloy.service.d/outside.conf
rm -f /etc/systemd/system/alloy.service.d/ruby.conf   # this drop-in's old name
usermod -aG systemd-journal,adm alloy
install -d -o alloy -g alloy -m 0750 /var/lib/alloy /var/lib/alloy/data
alloy validate /etc/alloy >/dev/null

systemctl daemon-reload
systemctl enable --quiet alloy
systemctl restart alloy
systemctl is-active --quiet alloy || { journalctl -u alloy --no-pager -n 20; exit 1; }

echo "== lines landing in loki"
for _ in $(seq 1 12); do
  n=$(curl -sS --max-time 10 --cacert "$ROOT_CA" -G "$LOKI/loki/api/v1/query" \
        --data-urlencode "query=sum(count_over_time({host=\"$host\"}[10m]))" 2>/dev/null \
      | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(int(r[0]["value"][1]) if r else 0)' 2>/dev/null \
      || echo 0)
  [[ ${n:-0} -gt 0 ]] && { echo "   loki has $n lines for host=\"$host\" in the last 10 minutes"; exit 0; }
  sleep 5
done
echo "!! no lines for host=\"$host\" in loki after 60s"
journalctl -u alloy --no-pager -n 20
exit 1
