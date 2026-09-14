#!/usr/bin/env bash
# Jellyfin (192.168.1.60): UI on plain HTTP 8096; HTTPS on 8920 for Prometheus.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.1.60

require_enrolled "$HOST"
push "$HOST" root
$SSH "root@$HOST" '
  set -e
  usermod -aG tlscert jellyfin
  chmod +x /etc/homelab-tls/post-renew.d/20-jellyfin
  chown root:jellyfin /etc/jellyfin/network.xml && chmod 0640 /etc/jellyfin/network.xml
  # Builds the PKCS#12 bundle. Must happen before the restart: Jellyfin fails
  # to start if CertificatePath points at a file that is not there.
  /etc/homelab-tls/post-renew.d/20-jellyfin
'
echo "   jellyfin restarted (pfx rebuilt)"
