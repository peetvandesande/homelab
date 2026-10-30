#!/usr/bin/env bash
# Install sogode.com's vhost on ruby. From the clone, with sudo:
#   sudo ~/homelab/wordpress/scripts/install-ruby.sh
# Replaces the live file whole, after showing the diff and keeping a dated
# backup; puts the backup back if nginx rejects the result. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
ip -4 addr show dev dummy0 2>/dev/null | grep -q "inet 192.168.254.254/" || {
  echo "not ruby: no 192.168.254.254 on dummy0"; exit 1; }
[[ -s /etc/nginx/snippets/home-lan-allow.conf ]] || {
  echo "!! /etc/nginx/snippets/home-lan-allow.conf is missing"; exit 1; }

SRC=ruby/etc/nginx/sites-available/sogode.com
LIVE=/etc/nginx/sites-available/sogode.com
BAK=$LIVE.bak-$(date +%F-%H%M%S)

if cmp -s "$SRC" "$LIVE"; then
  echo "== $LIVE is already current"
else
  echo "== changes to $LIVE"
  diff -u "$LIVE" "$SRC" || true
  cp -p "$LIVE" "$BAK"
  install -m 0644 "$SRC" "$LIVE"
  if ! nginx -t 2>/dev/null; then
    nginx -t || true
    cp -p "$BAK" "$LIVE"
    echo "!! nginx rejected it; $LIVE restored from $BAK"; exit 1
  fi
  systemctl reload nginx
  echo "   previous version kept as $BAK"
fi

# From ruby's public address: the internet. From dummy0: inside the allow list.
check() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 --interface "$1" \
            --resolve sogode.com:443:145.239.73.18 "https://sogode.com$2"; }
ok=1
for path in /wp-login.php /xmlrpc.php; do
  out=$(check 145.239.73.18 "$path"); in=$(check 192.168.254.254 "$path")
  echo "   $path   internet $out   tunnel $in"
  [[ $out == 403 && $in != 403 && $in != 000 ]] || ok=0
done
front=$(check 145.239.73.18 /)
echo "   /   internet $front"
[[ $front == 200 ]] || ok=0
(( ok )) || { echo "!! unexpected status codes"; exit 1; }
echo "== done"
