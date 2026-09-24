#!/usr/bin/env bash
# Moby (192.168.1.27): push the engine config and put TLS in front of its
# metrics.
#
# Run this AFTER ca/scripts/enrol.sh 192.168.1.27 moby - the nginx in front of
# the metrics endpoint points at /etc/homelab-tls/host.{crt,key} and will not
# start without them.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.1.27

require_enrolled "$HOST"
push "$HOST" root
$SSH "root@$HOST" '
  set -e
  chmod +x /etc/homelab-tls/post-renew.d/20-nginx
  install -d -m 0755 /opt/stacks
  # The extra LAN addresses the migrated stacks publish on. systemctl start is
  # idempotent - the script uses `ip addr replace` - and it has to happen
  # before the engine restart below, or a container that binds .73 or .74
  # comes up broken.
  chmod +x /usr/local/sbin/homelab-extra-addresses
  systemctl daemon-reload
  systemctl enable homelab-extra-addresses.service >/dev/null
  systemctl restart homelab-extra-addresses.service
  # The packaged default site is a second `default_server` on :80 and serves
  # the nginx splash page to the LAN. Nothing here wants it.
  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/metrics.conf /etc/nginx/sites-enabled/metrics.conf
  nginx -t
  systemctl enable nginx >/dev/null
  systemctl restart nginx
  # Validates daemon.json without restarting anything: dockerd rejects an
  # unknown key outright, so a typo here would otherwise take the engine down
  # with every container on it.
  dockerd --validate --config-file /etc/docker/daemon.json
  systemctl enable docker >/dev/null
'
# A restart of the engine, not a reload: log-driver and metrics-addr are both
# daemon-start-time settings, SIGHUP does not pick them up. live-restore keeps
# running containers up across it - they are not stopped, only detached for
# the second the daemon is down.
restart_assert "$HOST" docker
echo "   docker restarted"

# No stack here is the repo's: nextcloud, traefik and xwiki came from the old
# moby, are host-owned, carry their own secrets, and nothing in this repo
# starts or stops them. A repo-owned stack would live in root/opt/stacks and
# be converged here with `docker compose up -d`.
