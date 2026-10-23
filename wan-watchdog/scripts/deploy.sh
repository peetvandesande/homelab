#!/usr/bin/env bash
# Install the WAN watchdog on the router: the script, the kmwan hotplug hook,
# the one-minute cron entry, and the sysupgrade.conf lines that keep the two
# files across a firmware upgrade. Idempotent.
set -euo pipefail

cd "$(dirname "$0")/.."

ROUTER=192.168.8.1
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"
CRON_LINE='* * * * * /usr/local/bin/wan-watchdog'

echo "== router: the watchdog"
# No install(1) on the router's busybox. Written to a temporary name and moved
# into place so a run that is in progress is never reading a half-written file.
$SSH "root@$ROUTER" 'cat > /usr/local/bin/wan-watchdog.tmp && chmod 0755 /usr/local/bin/wan-watchdog.tmp \
  && mv -f /usr/local/bin/wan-watchdog.tmp /usr/local/bin/wan-watchdog' \
  < router/usr/local/bin/wan-watchdog
echo "   /usr/local/bin/wan-watchdog (0755)"

echo "== router: the kmwan hotplug hook"
$SSH "root@$ROUTER" 'mkdir -p /etc/hotplug.d/kmwan \
  && cat > /etc/hotplug.d/kmwan/99-wan-watchdog.tmp && chmod 0755 /etc/hotplug.d/kmwan/99-wan-watchdog.tmp \
  && mv -f /etc/hotplug.d/kmwan/99-wan-watchdog.tmp /etc/hotplug.d/kmwan/99-wan-watchdog' \
  < router/etc/hotplug.d/kmwan/99-wan-watchdog
echo "   /etc/hotplug.d/kmwan/99-wan-watchdog (0755)"

echo "== router: cron entry"
# /etc/crontabs/ is already in /lib/upgrade/keep.d/busybox, so the entry
# survives a sysupgrade on its own. crond re-reads the file on change, but
# restart it so a fresh install does not wait for the next minute boundary.
$SSH "root@$ROUTER" "
  set -e
  f=/etc/crontabs/root
  mkdir -p /etc/crontabs
  touch \$f
  grep -vF '/usr/local/bin/wan-watchdog' \$f > \$f.tmp || true
  echo '$CRON_LINE' >> \$f.tmp
  mv -f \$f.tmp \$f
  chmod 600 \$f
  /etc/init.d/cron enable >/dev/null 2>&1 || true
  /etc/init.d/cron restart >/dev/null 2>&1
"
echo "   $CRON_LINE"

echo "== router: kept across firmware upgrades"
# /usr/local/bin/ is already listed (router-metrics and vpn-policy-dump live
# there). The hotplug hook is not a package conffile, so without this line a
# sysupgrade silently drops it and the watchdog stops being triggered early.
$SSH "root@$ROUTER" '
  set -e
  for p in /usr/local/bin/ /etc/hotplug.d/kmwan/99-wan-watchdog; do
    grep -qxF "$p" /etc/sysupgrade.conf || echo "$p" >> /etc/sysupgrade.conf
  done
  grep -E "^(/usr/local/bin/|/etc/hotplug.d/)" /etc/sysupgrade.conf | sed "s/^/   /"'

echo
echo "== one sweep, to prove it runs"
# Healthy sweeps are silent by design, so ask for the exit status rather than
# output. A non-zero exit here means the script itself is broken.
$SSH "root@$ROUTER" '/usr/local/bin/wan-watchdog; echo "   exit=$?"'

echo
echo "== deployed - now run scripts/verify.sh"
