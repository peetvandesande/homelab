#!/usr/bin/env bash
# Moby (192.168.8.27): push the engine config and put TLS in front of its
# metrics.
#
# Run this AFTER ca/scripts/enrol.sh 192.168.8.27 moby - the nginx in front of
# the metrics endpoint points at /etc/homelab-tls/host.{crt,key} and will not
# start without them.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.27

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
  ln -sf /etc/nginx/sites-available/n8n.conf /etc/nginx/sites-enabled/n8n.conf
  ln -sf /etc/nginx/sites-available/n8n-sogode.conf /etc/nginx/sites-enabled/n8n-sogode.conf
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

# Repo-owned stacks: root/opt/stacks/<name>, converged with `docker compose
# up -d`. nextcloud, traefik and xwiki are NOT among them - they came from the
# old moby, are host-owned, carry their own secrets, and nothing in this repo
# starts or stops them.
#
# A stack's secrets are its .env. The database password and the encryption
# key are generated here the first time and never again: n8n's
# N8N_ENCRYPTION_KEY encrypts every credential it stores, so a new one would
# orphan them all. The mail password comes from homelab-private and is
# rewritten on every deploy, over stdin.
converge_n8n() {  # <stack> <secrets file in homelab-private>
  local stack=$1 secrets=$2 smtp
  [[ -f $secrets ]] || { echo "$secrets missing"; exit 1; }
  smtp=$(sed -n 's/^SMTP_PASSWD=//p' "$secrets")
  [[ -n $smtp ]] || { echo "SMTP_PASSWD unset in $secrets"; exit 1; }
  printf '%s\n' "$smtp" | $SSH "root@$HOST" "stack=$stack"'
    set -e
    env=/opt/stacks/$stack/.env
    umask 077
    if [ ! -s "$env" ]; then
      printf "POSTGRES_PASSWORD=%s\nN8N_ENCRYPTION_KEY=%s\n" \
        "$(openssl rand -hex 24)" "$(openssl rand -hex 32)" > "$env"
      echo "   generated $env"
    fi
    read -r pass
    # The sandbox, task-runner and SearXNG secrets, generated once alongside
    # the others.
    for k in SANDBOX_API_KEY SANDBOX_REGISTRATION_TOKEN SANDBOX_RUNNER_KEY N8N_RUNNERS_AUTH_TOKEN SEARXNG_SECRET; do
      grep -q "^$k=" "$env" || { printf "%s=%s\n" "$k" "$(openssl rand -hex 32)" >> "$env"; echo "   generated $k"; }
    done
    { grep -v "^N8N_SMTP_PASS=" "$env"; printf "N8N_SMTP_PASS=%s\n" "$pass"; } > "$env.new"
    mv "$env.new" "$env"
    chmod 0600 "$env"
    cd /opt/stacks/$stack
    docker compose pull -q
    docker compose up -d --remove-orphans
  '
  echo "   $stack converged"
}
converge_n8n n8n ../../homelab-private/n8n/secrets.env
converge_n8n n8n-sogode ../../homelab-private/n8n-sogode/secrets.env
