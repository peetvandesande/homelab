#!/usr/bin/env bash
# OpenTofu's shared state: a database on forgejo's PostgreSQL, and the read-only
# Proxmox token used to plan. Safe to re-run; values that exist are kept.
#
# Creates ~/projects/homelab-private/tofu/secrets.env on first run. Put it in
# Bitwarden straight afterwards with infra/scripts/vault.py import.
set -euo pipefail
cd "$(dirname "$0")/../state"
# shellcheck disable=SC1091
source ../../ca/scripts/lib.sh
FORGEJO=192.168.8.62
LENORA=192.168.8.21
SECRETS=${HOMELAB_PRIVATE:-$HOME/projects/homelab-private}/tofu/secrets.env

require_enrolled "$FORGEJO"

if [[ ! -s $SECRETS ]]; then
  mkdir -p "$(dirname "$SECRETS")"
  # An auditor can read every guest's settings and change nothing.
  token=$($SSH "root@$LENORA" '
    set -e
    pveum user list --output-format json | grep -q "\"userid\":\"tofu-read@pve\"" \
      || pveum user add tofu-read@pve --comment "OpenTofu, read-only"
    pveum acl modify / --users tofu-read@pve --roles PVEAuditor
    pveum user token remove tofu-read@pve plan >/dev/null 2>&1 || true
    pveum user token add tofu-read@pve plan --privsep 0 --output-format json
  ' | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["value"])')
  [[ -n $token ]] || { echo "could not create the Proxmox token"; exit 1; }
  ( umask 077
    { echo "TOFU_STATE_PG_PASSWORD=$(openssl rand -hex 32)"
      echo "TOFU_STATE_PASSPHRASE=$(openssl rand -hex 32)"
      echo "PROXMOX_VE_API_TOKEN=tofu-read@pve!plan=$token"
    } > "$SECRETS" )
  echo "   created $SECRETS; run infra/scripts/vault.py import"
fi

push "$FORGEJO" root

sed -n 's/^TOFU_STATE_PG_PASSWORD=//p' "$SECRETS" | $SSH "root@$FORGEJO" '
  set -e
  read -r password
  chmod +x /etc/homelab-tls/post-renew.d/30-postgresql
  usermod -aG tlscert postgres
  # Only this database, only this role, only over TLS, and only from the LAN.
  # ruby proxies nothing to this port, so it is not reachable from outside.
  line="hostssl tofu_state tofu 192.168.8.0/24 scram-sha-256"
  grep -qxF "$line" /etc/postgresql/17/main/pg_hba.conf || echo "$line" >> /etc/postgresql/17/main/pg_hba.conf
  runuser -u postgres -- psql -tA -c "\du tofu" | grep -q "^tofu" || runuser -u postgres -- createuser tofu
  runuser -u postgres -- psql -tA -l | grep -q "^tofu_state|" || runuser -u postgres -- createdb -O tofu -E UTF8 -T template0 tofu_state
  printf "ALTER ROLE tofu PASSWORD '"'"'%s'"'"';\n" "$password" | runuser -u postgres -- psql -q
'
if $SSH "root@$FORGEJO" 'ss -ltn | grep -q "192.168.8.62:5432"'; then
  $SSH "root@$FORGEJO" 'pg_ctlcluster 17 main reload'
  echo "   postgresql reloaded"
else
  # Only a restart applies listen_addresses. Forgejo reconnects by itself.
  restart_assert "$FORGEJO" postgresql@17-main
  echo "   postgresql restarted"
fi
$SSH "root@$FORGEJO" 'ss -ltn | grep -q "192.168.8.62:5432"' || { echo "not listening on the LAN"; exit 1; }
echo "   state database ready"
