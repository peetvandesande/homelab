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

# Forgejo Actions runner (root/etc/forgejo-runner/config.yml for what it may
# do and why). It connects with the shared secret that forgejo/scripts/deploy.sh
# registers on the Forgejo side; both read it from homelab-private. Run
# forgejo's deploy first, or the runner is refused until it is. The job
# search deploy (sogode-jobsearch/ci/deploy.sh) gets its n8n API keys and the
# Forgejo read token from /etc/forgejo-runner/jobsearch.env, rewritten here
# on every deploy - so Forgejo itself stores no secrets for it.
RUNNER_VERSION=13.2.0
RUNNER_SECRET=$(sed -n 's/^RUNNER_MOBY_SECRET=//p' ../../homelab-private/forgejo/secrets.env)
[[ $RUNNER_SECRET =~ ^[0-9a-f]{40}$ ]] \
  || { echo "RUNNER_MOBY_SECRET in homelab-private/forgejo/secrets.env must be 40 hex characters"; exit 1; }
JOBSEARCH_SECRETS=../../homelab-private/jobsearch/secrets.env
runner_env=""
for k in SOGODE_N8N_API_KEY PERSONAL_N8N_API_KEY FORGEJO_TOKEN; do
  v=$(sed -n "s/^$k=//p" "$JOBSEARCH_SECRETS")
  [[ -n $v ]] || { echo "$k unset in $JOBSEARCH_SECRETS"; exit 1; }
  runner_env+="$k=$v"$'\n'
done
{ printf '%s\n' "$RUNNER_SECRET"; printf '%s' "$runner_env"; } | $SSH "root@$HOST" "v=$RUNNER_VERSION"'
  set -e
  read -r secret
  getent passwd forgejo-runner >/dev/null \
    || useradd --system --home-dir /var/lib/forgejo-runner --shell /usr/sbin/nologin forgejo-runner
  install -d -o forgejo-runner -g forgejo-runner -m 0750 /var/lib/forgejo-runner /var/lib/forgejo-runner/work
  ( umask 027; cat > /etc/forgejo-runner/jobsearch.env.new )
  chown root:forgejo-runner /etc/forgejo-runner/jobsearch.env.new
  mv -f /etc/forgejo-runner/jobsearch.env.new /etc/forgejo-runner/jobsearch.env

  # The binary, checked against the release checksum.
  if ! /usr/local/bin/forgejo-runner --version 2>/dev/null | grep -q "v$v\b"; then
    url=https://code.forgejo.org/forgejo/runner/releases/download/v$v/forgejo-runner-$v-linux-amd64
    tmp=$(mktemp)
    curl -fsSL -o "$tmp" "$url"
    echo "$(curl -fsSL "$url.sha256" | cut -d" " -f1)  $tmp" | sha256sum -c --quiet
    install -m 0755 "$tmp" /usr/local/bin/forgejo-runner
    rm -f "$tmp"
    echo "   forgejo-runner $v installed"
  fi
  # The job search deploy reads instance.yaml.
  dpkg -s python3-yaml >/dev/null 2>&1 || { apt-get update -q >/dev/null; apt-get install -y -q python3-yaml >/dev/null; }

  # The connection: the token is the secret itself, root-only, handed to the
  # service by LoadCredential; config.yml gets the UUID derived from it (push
  # installed it with a placeholder, as forgejo/ does with app.ini).
  ( umask 077; printf "%s" "$secret" > /etc/forgejo-runner/token )
  uuid=$(python3 -c "import sys, uuid; print(uuid.UUID(bytes=sys.argv[1][:16].encode()))" "${secret:0:16}")
  sed -i "s|@@RUNNER_UUID@@|$uuid|" /etc/forgejo-runner/config.yml
  chown root:forgejo-runner /etc/forgejo-runner/config.yml && chmod 0640 /etc/forgejo-runner/config.yml
  rm -f /var/lib/forgejo-runner/.runner
  systemctl daemon-reload
  systemctl enable forgejo-runner >/dev/null
'
restart_assert "$HOST" forgejo-runner
echo "   forgejo-runner restarted"
