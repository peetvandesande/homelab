#!/usr/bin/env bash
# Navidrome (192.168.1.61): HTTPS in place on 4533.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.1.61

require_enrolled "$HOST"
push "$HOST" root
$SSH "root@$HOST" '
  set -e
  usermod -aG tlscert navidrome
  chmod +x /etc/homelab-tls/post-renew.d/20-navidrome
  chown root:navidrome /etc/navidrome/navidrome.toml && chmod 0640 /etc/navidrome/navidrome.toml
'
restart_assert "$HOST" navidrome
echo "   navidrome restarted"
