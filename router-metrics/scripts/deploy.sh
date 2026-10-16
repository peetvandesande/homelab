#!/usr/bin/env bash
# Install router and ONT metrics: the read-only dump on the router, the two
# forced-command keys it runs behind, and the collector and timer on lenora.
# Idempotent - keys are created once and their authorized_keys lines replaced
# by comment, so a rerun after a router factory reset or a new ONT puts
# everything back.
set -euo pipefail

cd "$(dirname "$0")/.."

ROUTER=192.168.8.1
LENORA=192.168.8.21
ONT=192.168.11.1
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"
# The pon readings, one line per command, prefixed with its name. No quotes,
# so it sits in authorized_keys' command="" without escaping.
ONT_CMD='for c in psg gsg pdcg pucg fcg gtc_counters_get xgtc_counters_get; do echo $c $(pon $c); done; echo osg $(pon osg /sys/class/pon_mbox/pon_mbox0/device/eeprom50 /sys/class/pon_mbox/pon_mbox0/device/eeprom51)'
RESTRICT='no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty'

echo "== router: the dump"
# No install(1) on the router's busybox.
$SSH "root@$ROUTER" 'cat > /usr/local/bin/router-metrics.tmp && chmod 0755 /usr/local/bin/router-metrics.tmp \
  && mv -f /usr/local/bin/router-metrics.tmp /usr/local/bin/router-metrics' \
  < router/usr/local/bin/router-metrics
echo "   /usr/local/bin/router-metrics (0755)"

echo "== router -> ONT key"
# Its own key, kept across upgrades; /usr/local/bin/ is already in
# sysupgrade.conf for vpn-policy-dump.
ONT_PUB=$($SSH "root@$ROUTER" '
  set -e
  k=/etc/dropbear/ont_metrics_key
  [ -f $k ] || dropbearkey -t ed25519 -f $k >/dev/null
  grep -qxF $k /etc/sysupgrade.conf || echo $k >> /etc/sysupgrade.conf
  dropbearkey -y -f $k | grep ^ssh- | cut -d" " -f1,2')
$SSH -J "root@$ROUTER" "root@$ONT" "
  set -e
  f=/etc/dropbear/authorized_keys
  grep -v ' router-metrics@router\$' \$f > \$f.tmp || true
  echo 'command=\"$ONT_CMD\",$RESTRICT $ONT_PUB router-metrics@router' >> \$f.tmp
  chmod 600 \$f.tmp && mv -f \$f.tmp \$f"
echo "   authorised on the ONT, forced to the pon readings"

echo "== lenora -> router key"
LENORA_PUB=$($SSH "root@$LENORA" '
  set -e
  k=/root/.ssh/router_metrics
  [ -f $k ] || ssh-keygen -q -t ed25519 -N "" -C router-metrics@lenora -f $k
  cut -d" " -f1,2 $k.pub')
$SSH "root@$ROUTER" "
  set -e
  f=/etc/dropbear/authorized_keys
  grep -v ' router-metrics@lenora\$' \$f > \$f.tmp || true
  echo 'command=\"/usr/local/bin/router-metrics\",$RESTRICT $LENORA_PUB router-metrics@lenora' >> \$f.tmp
  chmod 600 \$f.tmp && mv -f \$f.tmp \$f"
echo "   authorised on the router, forced to router-metrics"

echo "== lenora: the collector"
push() { # push <local> <remote> <mode>
  echo "   $2 ($3)"
  $SSH "root@$LENORA" "install -D -m $3 /dev/stdin $2" < "$1"
}
push lenora/usr/local/bin/homelab-router-metrics /usr/local/bin/homelab-router-metrics 0755
push lenora/etc/systemd/system/homelab-router-metrics.service \
     /etc/systemd/system/homelab-router-metrics.service 0644
push lenora/etc/systemd/system/homelab-router-metrics.timer \
     /etc/systemd/system/homelab-router-metrics.timer 0644

$SSH "root@$LENORA" '
  set -e
  # Accept the router host key once, as root, the way the collector connects.
  ssh -i /root/.ssh/router_metrics -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      root@192.168.8.1 >/dev/null
  systemctl daemon-reload
  systemctl enable --now homelab-router-metrics.timer >/dev/null
  systemctl start homelab-router-metrics.service
'
echo
echo "== deployed - now run scripts/verify.sh"
