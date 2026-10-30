#!/usr/bin/env bash
# Install sogode.com's vhost on ruby. From the clone, with sudo:
#   sudo ~/homelab/wordpress/scripts/install-ruby.sh
# Replaces the live file whole, keeping a dated backup, and puts the backup
# back if nginx rejects the result. Safe to re-run.
set -euo pipefail
shopt -s extglob
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
ip -4 addr show dev dummy0 2>/dev/null | grep -q "inet 192.168.254.254/" || {
  echo "not ruby: no 192.168.254.254 on dummy0"; exit 1; }
[[ -s /etc/nginx/snippets/home-lan-allow.conf ]] || {
  echo "!! /etc/nginx/snippets/home-lan-allow.conf is missing"; exit 1; }

SRC=ruby/etc/nginx/sites-available/sogode.com
LIVE=/etc/nginx/sites-available/sogode.com
BAK=$LIVE.bak-$(date +%F-%H%M%S)
PUB4=145.239.73.18
PUB6=2001:41d0:305:2100::1:3a0e

if cmp -s "$SRC" "$LIVE"; then
  echo "== $LIVE is already current"
else
  d=$(diff "$LIVE" "$SRC" || true)
  echo "== $LIVE: +$(grep -c '^>' <<<"$d") -$(grep -c '^<' <<<"$d") lines"
  cp -p "$LIVE" "$BAK"
  install -m 0644 "$SRC" "$LIVE"
  if ! nginx -t 2>/dev/null; then
    nginx -t || true
    cp -p "$BAK" "$LIVE"
    echo "!! nginx rejected it; $LIVE restored"; exit 1
  fi
  systemctl reload nginx
  echo "   previous version: $BAK (diff -u $BAK $LIVE)"
fi

# status <source address> <url> [curl args]: the code, then the redirect target.
status() { local src=$1 url=$2; shift 2
  curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 --interface "$src" \
       --resolve "sogode.com:80:$PUB4" --resolve "sogode.com:443:$PUB4" "$@" "$url"; }

# reload returns before the old workers have gone, so wait for the new config.
for _ in $(seq 1 20); do
  [[ $(status "$PUB4" https://sogode.com/wp-login.php) == "403 "* ]] && break
  sleep 0.5
done

fail=0
report() { # report <label> <actual> <wanted> <0|1 passed>
  if (( $4 )); then printf '   ok    %-30s %s\n' "$1" "$2"
  else printf '   FAIL  %-30s %s (wanted %s)\n' "$1" "$2" "$3"; fail=1; fi; }
expect() { local ok=0; [[ $3 == $2 ]] && ok=1; report "$1" "$3" "$2" $ok; }   # matches a glob
refuse() { local ok=1; [[ $3 == $2 ]] && ok=0; report "$1" "$3" "not $2" $ok; } # must not

# ruby's public address is the internet; dummy0 is inside the allow list.
for p in /wp-login.php /xmlrpc.php; do
  expect "$p from the internet" "403 " "$(status $PUB4 https://sogode.com$p)"
  refuse "$p over the tunnel" "@(403|000) *" "$(status 192.168.254.254 https://sogode.com$p)"
done
expect "front page" "200 " "$(status $PUB4 https://sogode.com/)"
expect "http keeps the path" "301 https://sogode.com/a/b" "$(status $PUB4 http://sogode.com/a/b)"
expect "/meet/peet" "302 https://outlook.office.com/*" "$(status $PUB4 https://sogode.com/meet/peet)"
expect "/alkira" "301 https://www.youtube.com/*" "$(status $PUB4 https://sogode.com/alkira)"
refuse "2 MB upload" "@(413|000) *" "$(head -c 2000000 /dev/zero |
  status 192.168.254.254 https://sogode.com/wp-admin/async-upload.php -X POST --data-binary @-)"
expect "social.sogode.com over IPv6" "[1-5][0-9][0-9] *" "$(curl -s -o /dev/null -w '%{http_code} ' \
  --max-time 10 --resolve "social.sogode.com:443:[$PUB6]" https://social.sogode.com/)"

(( fail == 0 )) || { echo "!! some checks failed"; exit 1; }
echo "== done"
