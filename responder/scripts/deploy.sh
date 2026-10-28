#!/usr/bin/env bash
# Alert responder on lexie (192.168.8.24): receive Grafana's webhook, have
# Claude investigate read-only, push the finding to Home Assistant.
#
# Needs homelab-private/responder/secrets.env (mode 600) with HA_WEBHOOK_ID,
# the same id as grafana's. RESPONDER_TOKEN is generated on the first run and
# appended; grafana/scripts/deploy.sh reads it from there.
#
# Claude must be logged in as the responder user once, by hand - see CLAUDE.md.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.24

SECRETS=../../homelab-private/responder/secrets.env
[[ -f $SECRETS ]] || { echo "$SECRETS missing - see CLAUDE.md"; exit 1; }
if ! grep -q '^RESPONDER_TOKEN=' "$SECRETS"; then
  echo "RESPONDER_TOKEN=$(openssl rand -hex 32)" >> "$SECRETS"
  echo "   generated RESPONDER_TOKEN"
fi
# shellcheck disable=SC1090
source "$SECRETS"
[[ -n "${HA_WEBHOOK_ID:-}" ]] || { echo "HA_WEBHOOK_ID unset in $SECRETS"; exit 1; }

$SSH "root@$HOST" '
  set -e
  id responder >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/responder \
    --shell /bin/bash --comment "alert responder" responder
  install -d -o responder -g responder -m 0700 /var/lib/responder /var/lib/responder/.ssh
  [ -f /var/lib/responder/.ssh/id_ed25519 ] || runuser -u responder -- \
    ssh-keygen -q -t ed25519 -N "" -C responder@lexie -f /var/lib/responder/.ssh/id_ed25519
  # IPv4 only: the hosts accept this key only from 192.168.8.24, and a name
  # that resolves to a ULA would otherwise connect from one and be refused.
  printf "Host *\\n  AddressFamily inet\\n" > /var/lib/responder/.ssh/config
  chown responder:responder /var/lib/responder/.ssh/config && chmod 0600 /var/lib/responder/.ssh/config
  install -d -m 0755 /etc/responder
'
push "$HOST" root

# The env file carries the bearer token and the HA webhook id. Sent over stdin
# so neither lands in a remote command line.
printf 'RESPONDER_BIND=%s\nRESPONDER_TOKEN=%s\nRESPONDER_HA_URL=https://192.168.8.90/api/webhook/%s\n' \
  "$HOST" "$RESPONDER_TOKEN" "$HA_WEBHOOK_ID" | $SSH "root@$HOST" '
  cat > /etc/responder/responder.env.deploytmp && chown root:responder /etc/responder/responder.env.deploytmp \
  && chmod 0640 /etc/responder/responder.env.deploytmp && mv -f /etc/responder/responder.env.deploytmp /etc/responder/responder.env'
echo "   etc/responder/responder.env (0640 root:responder)"

$SSH "root@$HOST" 'chmod +x /etc/homelab-tls/post-renew.d/30-responder && usermod -aG tlscert responder && systemctl daemon-reload && systemctl enable responder >/dev/null 2>&1'
restart_assert "$HOST" responder
