#!/usr/bin/env bash
# Push the radio search card into Home Assistant's /config/www, which HA
# serves as /local/.
#
#   scripts/deploy-card.sh [--restart]
#
# HA only serves /local/ if /config/www existed when it started, so the first
# deploy into a fresh /config needs a real core restart - a quick reload from the
# UI is not enough. The script checks that HA actually serves the card;
# --restart restarts core if it does not, and without it the script just says so.
#
# The dashboard resource is registered by hand (Settings > Dashboards >
# Resources). Its ?v= has to change for browsers to drop a cached copy, so the
# URL to use is printed at the end.
set -euo pipefail

cd "$(dirname "$0")/.."

LENORA=192.168.8.21
VMID=302
CONFIG=/mnt/data/supervisor/homeassistant   # /config in the core container
CARD=www/radio-search-card.js
RESTART=0
[[ ${1:-} == --restart ]] && RESTART=1

SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

# Run a command in the guest, propagating the guest's own exit code.
qexec() {
  $SSH "root@$LENORA" "qm guest exec $VMID --timeout 120 -- /bin/sh -c $(printf '%q' "$1")" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.stdout.write(d.get("out-data", "") + d.get("err-data", ""))
sys.exit(int(d.get("exitcode") or 0))
'
}

echo "== pushing $CARD"
b64=$(base64 < "$CARD" | tr -d '\n')
qexec "mkdir -p $CONFIG/www && echo $b64 | base64 -d > $CONFIG/www/radio-search-card.js.new \
  && mv $CONFIG/www/radio-search-card.js.new $CONFIG/www/radio-search-card.js" >/dev/null

URL=https://homeassistant.home/local/radio-search-card.js
served() {
  [[ $(curl -s -o /dev/null -w '%{http_code}' --cacert ../ca/rootca/certs/root.crt "$URL") == 200 ]]
}

if ! served; then
  if (( RESTART )); then
    echo "== HA does not serve /local/ yet - restarting core"
    qexec "ha core restart" >/dev/null
    for _ in $(seq 1 30); do served && break; sleep 5; done
    served || { echo "!! still not served after the restart: $URL" >&2; exit 1; }
  else
    echo "!! HA does not serve $URL - /config/www is probably newer than"
    echo "   HA's last start. Re-run with --restart (a quick reload is not enough)."
    exit 1
  fi
fi

version=$(shasum -a 256 "$CARD" | cut -c1-8)
echo "== done. Dashboard resource (JavaScript module):"
echo "   /local/radio-search-card.js?v=$version"
