#!/usr/bin/env bash
# Install the Wi-Fi watchdog on the router: the script and its one-minute cron
# entry. /usr/local/bin/ and /etc/crontabs/ already survive a sysupgrade.
# Idempotent.
set -euo pipefail

cd "$(dirname "$0")/.."

ROUTER=192.168.8.1
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"
CRON_LINE='* * * * * /usr/local/bin/wifi-watchdog'

echo "== router: the watchdog"
# No install(1) on the router's busybox. Written to a temporary name and moved
# into place so a run in progress never reads a half-written file.
$SSH "root@$ROUTER" 'cat > /usr/local/bin/wifi-watchdog.tmp && chmod 0755 /usr/local/bin/wifi-watchdog.tmp \
  && mv -f /usr/local/bin/wifi-watchdog.tmp /usr/local/bin/wifi-watchdog' \
  < router/usr/local/bin/wifi-watchdog
echo "   /usr/local/bin/wifi-watchdog (0755)"

echo "== router: cron entry"
$SSH "root@$ROUTER" "
  set -e
  f=/etc/crontabs/root
  mkdir -p /etc/crontabs
  touch \$f
  grep -vF '/usr/local/bin/wifi-watchdog' \$f > \$f.tmp || true
  echo '$CRON_LINE' >> \$f.tmp
  mv -f \$f.tmp \$f
  chmod 600 \$f
  /etc/init.d/cron enable >/dev/null 2>&1 || true
  /etc/init.d/cron restart >/dev/null 2>&1
"
echo "   $CRON_LINE"

echo "== router: kept across firmware upgrades"
$SSH "root@$ROUTER" 'grep -qxF /usr/local/bin/ /etc/sysupgrade.conf || echo /usr/local/bin/ >> /etc/sysupgrade.conf'
echo "   /usr/local/bin/ in /etc/sysupgrade.conf"

echo
echo "== deployed - the next cron tick runs it; then scripts/verify.sh"
