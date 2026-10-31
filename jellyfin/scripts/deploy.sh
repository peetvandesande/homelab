#!/usr/bin/env bash
# Jellyfin (192.168.8.60): plain HTTP on 8096, UI and /metrics alike.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.60

push "$HOST" root
$SSH "root@$HOST" '
  set -e
  chown root:jellyfin /etc/jellyfin/network.xml && chmod 0640 /etc/jellyfin/network.xml
  # Left over from when 8920 served TLS: a renew hook that rebuilt the PKCS#12
  # bundle and restarted jellyfin, the bundle itself, and jellyfin in the group
  # that can read the key. Drop all three.
  rm -f /etc/homelab-tls/post-renew.d/20-jellyfin /etc/homelab-tls/jellyfin.pfx
  gpasswd -d jellyfin tlscert >/dev/null 2>&1 || true
'
restart_assert "$HOST" jellyfin
echo "   jellyfin restarted"
