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
  ln -sf /etc/nginx/sites-available/ntfy-sogode.conf /etc/nginx/sites-enabled/ntfy-sogode.conf
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

# The job search pipelines (sogode-jobsearch and personal-jobsearch repos).
# After the n8n stacks: every jobsearch stack joins an n8n stack's network,
# which has to exist first. Each instance's database password is generated
# here once; the pipelines' own deploy (sogode-jobsearch/ansible) reads it
# from the .env to build the n8n credential, and loads the schema.
converge_jobsearch() {  # <stack>
  local stack=$1
  $SSH "root@$HOST" "stack=$stack"'
    set -e
    env=/opt/stacks/$stack/.env
    umask 077
    [ -s "$env" ] || { printf "POSTGRES_PASSWORD=%s\n" "$(openssl rand -hex 24)" > "$env"; echo "   generated $env"; }
    chmod 0600 "$env"
    cd /opt/stacks/$stack
    docker compose pull -q
    docker compose up -d --remove-orphans
  '
  echo "   $stack converged"
}
converge_jobsearch jobsearch-sogode
converge_jobsearch jobsearch-personal

# Shared by both: render (built here), Gotenberg and ntfy. ntfy denies
# everything by default; its two users are (re)written from .env on every
# deploy - n8n may publish to jobs-*, peet may read them. peet's password is
# what goes into the phone app: `cat /opt/stacks/jobsearch-shared/.env`.
$SSH "root@$HOST" '
  set -e
  env=/opt/stacks/jobsearch-shared/.env
  umask 077
  touch "$env"
  for k in NTFY_N8N_PASSWORD NTFY_PEET_PASSWORD; do
    grep -q "^$k=" "$env" || { printf "%s=%s\n" "$k" "$(openssl rand -hex 16)" >> "$env"; echo "   generated $k"; }
  done
  chmod 0600 "$env"
  cd /opt/stacks/jobsearch-shared
  docker compose pull -q --ignore-buildable
  docker compose up -d --build --remove-orphans
  . ./.env
  for _ in $(seq 20); do docker compose exec -T ntfy ntfy user list >/dev/null 2>&1 && break; sleep 1; done
  for u in n8n:$NTFY_N8N_PASSWORD:write-only peet:$NTFY_PEET_PASSWORD:read-only; do
    name=${u%%:*}; rest=${u#*:}; pass=${rest%%:*}; perm=${rest#*:}
    if docker compose exec -T ntfy ntfy user list 2>&1 | grep -q "^user $name "; then
      docker compose exec -T -e NTFY_PASSWORD="$pass" ntfy ntfy user change-pass "$name" >/dev/null
    else
      docker compose exec -T -e NTFY_PASSWORD="$pass" ntfy ntfy user add "$name" >/dev/null
    fi
    docker compose exec -T ntfy ntfy access "$name" "jobs-*" "$perm" >/dev/null
  done
'
echo "   jobsearch-shared converged"

# CI's one way in (../forgejo-runner/, the Forgejo runner on lexie): the
# account jobsearch-ci, whose only key is that runner's, accepted from lexie
# only and forced to /usr/local/sbin/jobsearch-schema with no pty or
# forwarding. It is in the docker group because the command needs
# `docker exec` (there is no sudo here), and the forced command is what keeps
# that from being anything more. No password: locked.
CI_PUB=$($SSH root@192.168.8.24 'cat /var/lib/forgejo-runner/.ssh/id_ed25519.pub 2>/dev/null' || true)
if [[ $CI_PUB == ssh-ed25519\ * ]]; then
  printf '%s\n' "$CI_PUB" | $SSH "root@$HOST" '
    set -e
    read -r pub
    id jobsearch-ci >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/jobsearch-ci \
      --shell /bin/sh --comment "job search CI (forced command)" jobsearch-ci
    usermod -aG docker jobsearch-ci
    passwd -l jobsearch-ci >/dev/null
    install -d -o jobsearch-ci -g jobsearch-ci -m 0700 /var/lib/jobsearch-ci/.ssh
    printf "restrict,from=\"192.168.8.24\",command=\"/usr/local/sbin/jobsearch-schema\" %s\n" "$pub" \
      > /var/lib/jobsearch-ci/.ssh/authorized_keys
    chown jobsearch-ci:jobsearch-ci /var/lib/jobsearch-ci/.ssh/authorized_keys
    chmod 0600 /var/lib/jobsearch-ci/.ssh/authorized_keys
  '
  echo "   jobsearch-ci authorised for lexie's runner"
else
  echo "   no runner key on lexie yet: run forgejo-runner/scripts/deploy.sh, then this again"
fi

# The runner itself lived here from 5 November 2026 until it moved to lexie
# the same day. Removed, idempotently; python3-yaml, installed for it, stays.
$SSH "root@$HOST" '
  systemctl disable --now forgejo-runner >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/forgejo-runner.service /usr/local/bin/forgejo-runner
  rm -rf /etc/forgejo-runner /var/lib/forgejo-runner
  if id forgejo-runner >/dev/null 2>&1; then userdel forgejo-runner; echo "   old forgejo-runner removed"; fi
  systemctl daemon-reload
'
