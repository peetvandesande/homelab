#!/usr/bin/env bash
# Push the radio search card into Home Assistant's /config/www, which HA
# serves as /local/.
#
#   scripts/deploy-card.sh [--restart]
#
# HA only serves /local/ if /config/www existed when it started, so the first
# deploy into a fresh /config needs a core restart. --restart does that; without
# it the script just says so.
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

fresh=0
qexec "test -d $CONFIG/www" >/dev/null 2>&1 || fresh=1

echo "== pushing $CARD"
b64=$(base64 < "$CARD" | tr -d '\n')
qexec "mkdir -p $CONFIG/www && echo $b64 | base64 -d > $CONFIG/www/radio-search-card.js.new \
  && mv $CONFIG/www/radio-search-card.js.new $CONFIG/www/radio-search-card.js" >/dev/null

if (( fresh )); then
  if (( RESTART )); then
    echo "== /config/www is new - restarting Home Assistant core"
    qexec "ha core restart" >/dev/null
  else
    echo "!! /config/www did not exist before - HA will not serve /local/ until"
    echo "   core restarts. Re-run with --restart, or restart it from the UI."
  fi
fi

version=$(shasum -a 256 "$CARD" | cut -c1-8)
echo "== done. Dashboard resource (JavaScript module):"
echo "   /local/radio-search-card.js?v=$version"
