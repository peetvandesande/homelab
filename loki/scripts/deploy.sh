#!/usr/bin/env bash
# Loki (192.168.1.56): push the config and serve the API over TLS.
#
# Run this AFTER ca/scripts/enrol.sh 192.168.1.56 loki - the config points at
# /etc/homelab-tls/host.{crt,key} and Loki will not start without them.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.1.56

require_enrolled "$HOST"
push "$HOST" root
$SSH "root@$HOST" '
  set -e
  usermod -aG tlscert loki
  chown root:loki /etc/loki/config.yml && chmod 0640 /etc/loki/config.yml
  chmod +x /etc/homelab-tls/post-renew.d/20-loki
  install -d -o loki -g loki -m 0750 /var/lib/loki
  # -verify-config parses and validates without starting anything. It runs as
  # root here, so it proves the YAML, not that loki can read the key - the
  # restart below proves that.
  loki -config.file=/etc/loki/config.yml -verify-config >/dev/null
  systemctl daemon-reload
  systemctl enable loki >/dev/null
'
restart_assert "$HOST" loki
echo "   loki restarted"
