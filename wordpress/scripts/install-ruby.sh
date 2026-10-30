#!/usr/bin/env bash
# Close sogode.com's wp-login.php and xmlrpc.php to the internet. From ruby's
# clone, with sudo:
#   sudo ~/homelab/wordpress/scripts/install-ruby.sh
# The vhost itself is hand-managed on ruby; this adds one include line to it
# and reverts the file if nginx rejects the result. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
ip -4 addr show dev dummy0 2>/dev/null | grep -q "inet 192.168.254.254/" || {
  echo "not ruby: no 192.168.254.254 on dummy0"; exit 1; }

VHOST=/etc/nginx/sites-available/sogode.com
SNIPPET=sogode-wordpress-private.conf
UPSTREAM='proxy_pass http://localhost:19080;'
[[ -s /etc/nginx/snippets/home-lan-allow.conf ]] || { echo "!! home-lan-allow.conf is missing"; exit 1; }
[[ $(grep -c "^[[:space:]]*$UPSTREAM" "$VHOST") -eq 1 ]] || {
  echo "!! expected exactly one '$UPSTREAM' in $VHOST - edit by hand"; exit 1; }

install -m 0644 "ruby/etc/nginx/snippets/$SNIPPET" "/etc/nginx/snippets/$SNIPPET"
if ! grep -q "include snippets/$SNIPPET;" "$VHOST"; then
  cp -p "$VHOST" "$VHOST.bak-$(date +%F)"
  sed -i "s|^\([[:space:]]*\)$UPSTREAM|&\n\n\1include snippets/$SNIPPET;|" "$VHOST"
fi
if ! nginx -t 2>&1 | tail -1 | grep -q successful; then
  nginx -t || true
  [[ -e $VHOST.bak-$(date +%F) ]] && cp -p "$VHOST.bak-$(date +%F)" "$VHOST"
  echo "!! nginx rejected the change; $VHOST restored"; exit 1
fi
systemctl reload nginx

# From ruby's public address: the internet. From dummy0: inside the allow list.
check() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 --interface "$1" \
            --resolve sogode.com:443:145.239.73.18 "https://sogode.com$2"; }
ok=1
for path in /wp-login.php /xmlrpc.php; do
  out=$(check 145.239.73.18 "$path"); in=$(check 192.168.254.254 "$path")
  echo "   $path   internet $out   tunnel $in"
  [[ $out == 403 && $in != 403 ]] || ok=0
done
echo "   /   internet $(check 145.239.73.18 /)"
(( ok )) || { echo "!! unexpected status codes"; exit 1; }
echo "== done"
