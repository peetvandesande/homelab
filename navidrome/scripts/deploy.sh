#!/usr/bin/env bash
# Navidrome (192.168.1.61): plain HTTP on 4533.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.1.61

push "$HOST" root
$SSH "root@$HOST" '
  set -e
  chown root:navidrome /etc/navidrome/navidrome.toml && chmod 0640 /etc/navidrome/navidrome.toml
  # Left over from when 4533 served TLS: a renew hook that restarted
  # navidrome, and navidrome in the group that can read the key. Drop both.
  rm -f /etc/homelab-tls/post-renew.d/20-navidrome
  gpasswd -d navidrome tlscert >/dev/null 2>&1 || true
'
restart_assert "$HOST" navidrome
echo "   navidrome restarted"
