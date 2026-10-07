#!/usr/bin/env bash
# Install the renewal driver, the helper it pushes, and the timer on lenora.
# Idempotent. Does not touch Home Assistant's own configuration.
set -euo pipefail

cd "$(dirname "$0")/.."

LENORA=192.168.8.21
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

# One file at a time, written as root:root - same reasoning as the other deploy
# scripts here, which learned not to stream tarballs into /.
push() { # push <local> <remote> <mode>
  echo "   $2 ($3)"
  $SSH "root@$LENORA" "install -D -m $3 /dev/stdin $2" < "$1"
}

echo "== pushing to $LENORA"
push lenora/usr/local/bin/homelab-ha-tls-renew /usr/local/bin/homelab-ha-tls-renew 0755
push haos/ha-tls.py /usr/local/share/homelab/ha-tls.py 0644
push lenora/etc/systemd/system/homelab-ha-tls-renew.service \
     /etc/systemd/system/homelab-ha-tls-renew.service 0644
push lenora/etc/systemd/system/homelab-ha-tls-renew.timer \
     /etc/systemd/system/homelab-ha-tls-renew.timer 0644

$SSH "root@$LENORA" '
  set -e
  systemctl daemon-reload
  systemctl enable --now homelab-ha-tls-renew.timer >/dev/null
  systemctl list-timers homelab-ha-tls-renew.timer --no-pager | head -2
'
echo
echo "== deployed - now run scripts/verify.sh"
