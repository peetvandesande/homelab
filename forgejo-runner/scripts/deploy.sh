#!/usr/bin/env bash
# Forgejo Actions runner on lexie (192.168.8.24): host jobs for peet's
# repositories under the label `lexie` (CLAUDE.md for what a job may do).
#
# Order: forgejo/scripts/deploy.sh first (registers the runner with the shared
# secret), then this, then moby/scripts/deploy.sh (authorises this runner's
# key for jobsearch-schema - until then the job search deploy fails at the
# schema step).
#
# Secrets, all from homelab-private: RUNNER_LEXIE_SECRET in forgejo/secrets.env,
# and the job search deploy's SOGODE_N8N_API_KEY, PERSONAL_N8N_API_KEY and
# FORGEJO_TOKEN in jobsearch/secrets.env. Sent over stdin, never argv.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.24
MOBY=192.168.8.27
RUNNER_VERSION=13.2.0

RUNNER_SECRET=$(sed -n 's/^RUNNER_LEXIE_SECRET=//p' ../../homelab-private/forgejo/secrets.env)
[[ $RUNNER_SECRET =~ ^[0-9a-f]{40}$ ]] \
  || { echo "RUNNER_LEXIE_SECRET in homelab-private/forgejo/secrets.env must be 40 hex characters"; exit 1; }
JOBSEARCH_SECRETS=../../homelab-private/jobsearch/secrets.env
job_env=""
for k in SOGODE_N8N_API_KEY PERSONAL_N8N_API_KEY FORGEJO_TOKEN; do
  v=$(sed -n "s/^$k=//p" "$JOBSEARCH_SECRETS")
  [[ -n $v ]] || { echo "$k unset in $JOBSEARCH_SECRETS"; exit 1; }
  job_env+="$k=$v"$'\n'
done

# The account and its one key. IPv4 only, like the responder's: moby accepts
# the key from 192.168.8.24 only, and a name resolving to a ULA would connect
# from one and be refused. `moby` in its ssh config is the jobsearch-ci
# account there; its host key is seeded rather than trusted on first use.
$SSH "root@$HOST" "moby=$MOBY"'
  set -e
  getent passwd forgejo-runner >/dev/null \
    || useradd --system --create-home --home-dir /var/lib/forgejo-runner --shell /usr/sbin/nologin \
         --comment "Forgejo Actions runner" forgejo-runner
  h=/var/lib/forgejo-runner
  install -d -o forgejo-runner -g forgejo-runner -m 0750 $h $h/work
  install -d -o forgejo-runner -g forgejo-runner -m 0700 $h/.ssh
  [ -f $h/.ssh/id_ed25519 ] || runuser -u forgejo-runner -- \
    ssh-keygen -q -t ed25519 -N "" -C forgejo-runner@lexie -f $h/.ssh/id_ed25519
  printf "Host moby\n  HostName %s\n  User jobsearch-ci\n  IdentityFile %s/.ssh/id_ed25519\n  IdentitiesOnly yes\n  AddressFamily inet\n  BatchMode yes\n" \
    "$moby" "$h" > $h/.ssh/config
  ssh-keyscan -q -t ed25519 "$moby" > $h/.ssh/known_hosts 2>/dev/null
  [ -s $h/.ssh/known_hosts ] || { echo "could not scan moby host key"; exit 1; }
  chown forgejo-runner:forgejo-runner $h/.ssh/config $h/.ssh/known_hosts
  chmod 0600 $h/.ssh/config $h/.ssh/known_hosts
  # The job search deploy reads instance.yaml.
  python3 -c "import yaml" 2>/dev/null || { apt-get update -q >/dev/null; apt-get install -y -q python3-yaml >/dev/null; }
'
push "$HOST" root

{ printf '%s\n' "$RUNNER_SECRET"; printf '%s' "$job_env"; } | $SSH "root@$HOST" "v=$RUNNER_VERSION"'
  set -e
  read -r secret
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

  # The connection: the token is the secret itself, root-only, handed to the
  # service by LoadCredential; config.yml gets the UUID derived from it (push
  # installed it with a placeholder, as forgejo/ does with app.ini).
  ( umask 077; printf "%s" "$secret" > /etc/forgejo-runner/token )
  uuid=$(python3 -c "import sys, uuid; print(uuid.UUID(bytes=sys.argv[1].encode()))" "${secret:0:16}")
  sed -i "s|@@RUNNER_UUID@@|$uuid|" /etc/forgejo-runner/config.yml
  chown root:forgejo-runner /etc/forgejo-runner/config.yml && chmod 0640 /etc/forgejo-runner/config.yml
  systemctl daemon-reload
  systemctl enable forgejo-runner >/dev/null
'
# The runner ran on moby until 5 November 2026 with this same registration.
# Stop it before starting this one, so two daemons never poll with one token;
# moby/scripts/deploy.sh removes the rest of it.
$SSH "root@$MOBY" 'systemctl disable --now forgejo-runner >/dev/null 2>&1 || true'
restart_assert "$HOST" forgejo-runner
echo "   forgejo-runner restarted"
echo "   next: moby/scripts/deploy.sh, which authorises this key for jobsearch-schema:"
$SSH "root@$HOST" 'cat /var/lib/forgejo-runner/.ssh/id_ed25519.pub'
