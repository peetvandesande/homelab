#!/usr/bin/env bash
# The Forgejo Actions runner on talos, registered for peet/homelab only.
#
# Needs scripts/bootstrap.sh to have run and the repository to exist on Forgejo.
# The runner's secret is made on talos and never written anywhere else, so a
# rebuilt talos simply makes and registers a new one.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.59
FORGEJO=192.168.8.62
RUNNER_VERSION=13.2.0

push "$HOST" root

$SSH "root@$HOST" "v=$RUNNER_VERSION"'
  set -e
  if ! /usr/local/bin/forgejo-runner --version 2>/dev/null | grep -q "v$v\b"; then
    url=https://code.forgejo.org/forgejo/runner/releases/download/v$v/forgejo-runner-$v-linux-amd64
    tmp=$(mktemp)
    curl -fsSL -o "$tmp" "$url"
    echo "$(curl -fsSL "$url.sha256" | cut -d" " -f1)  $tmp" | sha256sum -c --quiet
    install -m 0755 "$tmp" /usr/local/bin/forgejo-runner
    rm -f "$tmp"
    echo "   forgejo-runner $v installed"
  fi
  ( umask 077; [ -s /etc/forgejo-runner/token ] || printf "%s" "$(openssl rand -hex 20)" > /etc/forgejo-runner/token )
  secret=$(cat /etc/forgejo-runner/token)
  uuid=$(python3 -c "import sys, uuid; print(uuid.UUID(bytes=sys.argv[1].encode()))" "${secret:0:16}")
  sed -i "s|@@RUNNER_UUID@@|$uuid|" /etc/forgejo-runner/config.yml
  chown root:forgejo-runner /etc/forgejo-runner/config.yml
  chmod 0640 /etc/forgejo-runner/config.yml
  systemctl daemon-reload
  systemctl enable forgejo-runner >/dev/null
'

# What the drift check needs: the state database and a read-only Proxmox token.
SECRETS=${HOMELAB_PRIVATE:-$HOME/projects/homelab-private}/tofu/secrets.env
$SSH "root@$HOST" '( umask 027; cat > /etc/forgejo-runner/tofu.env.new )
  chown root:forgejo-runner /etc/forgejo-runner/tofu.env.new
  mv -f /etc/forgejo-runner/tofu.env.new /etc/forgejo-runner/tofu.env' < "$SECRETS"

# Registering the same secret again updates the runner in place. Scoped to one
# repository, so no other repository's workflow can ever land on this host.
# --secret-stdin is a string flag that wants a value; the value is ignored.
$SSH "root@$HOST" 'cat /etc/forgejo-runner/token' | $SSH "root@$FORGEJO" \
  'runuser -u git -- /usr/local/bin/forgejo forgejo-cli actions register --config /etc/forgejo/app.ini \
     --work-path /var/lib/forgejo --name talos --scope peet/homelab --labels talos --secret-stdin=1 >/dev/null'
echo "   runner talos registered for peet/homelab"

restart_assert "$HOST" forgejo-runner
echo "   forgejo-runner restarted"
