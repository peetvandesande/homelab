#!/usr/bin/env bash
# Prometheus (192.168.1.53): serve the API over TLS, and scrape the migrated
# services over TLS.
#
# Run this AFTER node-exporter/scripts/deploy.sh. Until it runs, every `node`
# scrape fails; after it runs, any host that is not yet TLS fails instead.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.1.53

# Home Assistant's /api/prometheus wants a long-lived access token, so unlike
# every other job this one has a secret. It lives in secrets.env (gitignored,
# same shape as dns/) and is installed as a file rather than inlined into
# prometheus.yml, which is world-readable on the host.
#
# Optional on purpose: a checkout without secrets.env can still deploy, as
# long as the token is already on the host from a previous run.
[[ -f secrets.env ]] && { set -a; # shellcheck disable=SC1091
  source secrets.env; set +a; }

require_enrolled "$HOST"
push "$HOST" root

if [[ -n "${HOMEASSISTANT_TOKEN:-}" ]]; then
  # 0400 and owned by prometheus, not root:prometheus 0640: the packaged unit
  # sets PrivateUsers=true, which leaves supplementary groups unmapped - see
  # invariant 2. The uid is mapped, so ownership is what works.
  printf '%s' "$HOMEASSISTANT_TOKEN" | $SSH "root@$HOST" \
    "cat > /etc/prometheus/homeassistant.token \
     && chown prometheus:prometheus /etc/prometheus/homeassistant.token \
     && chmod 0400 /etc/prometheus/homeassistant.token"
  echo "   homeassistant.token installed"
else
  $SSH "root@$HOST" 'test -s /etc/prometheus/homeassistant.token' \
    || { echo "no HOMEASSISTANT_TOKEN in secrets.env and none on the host - the homeassistant job will fail to load"; exit 1; }
  echo "   homeassistant.token left as it is (no secrets.env)"
fi
$SSH "root@$HOST" '
  set -e
  usermod -aG tlscert prometheus
  chmod +x /etc/homelab-tls/post-renew.d/20-prometheus
  promtool check config /etc/prometheus/prometheus.yml
  systemctl daemon-reload
'
restart_assert "$HOST" prometheus
echo "   prometheus restarted"
