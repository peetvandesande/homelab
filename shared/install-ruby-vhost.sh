#!/usr/bin/env bash
# Install a public vhost on ruby that reverse-proxies a lab service over wg1,
# with a Let's Encrypt certificate. Called by a service's own wrapper - today
# forgejo/scripts/install-ruby.sh and moby/scripts/install-ruby.sh - never
# directly:
#
#   install-ruby-vhost.sh <vhost-file> <public-name> <origin.home>
#
# Run from ruby's clone, with sudo. Safe to re-run. Modelled on
# ca/scripts/install-ruby.sh, with two differences: these vhosts are HTTPS,
# so a certificate is issued before the vhost is enabled, and the upstream is
# HTTPS too, verified against the lab root.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
[[ $# -eq 3 ]] || { echo "usage: $0 <vhost-file> <public-name> <origin.home>"; exit 1; }
SRC=$1 NAME=$2 ORIGIN=$3
REPO=$(cd "$(dirname "$0")/.." && pwd)
ROOT_CA=/etc/nginx/homelab-root-g2.crt
PUBLIC4=145.239.73.18
PUBLIC6=2001:41d0:305:2100::1:3a0e

# ruby is identified by dummy0, as in outside/install.sh.
ip -4 addr show dev dummy0 2>/dev/null | grep -q "inet 192.168.254.254/" || {
  echo "not ruby: no 192.168.254.254 on dummy0"; exit 1; }
[[ -s $SRC ]] || { echo "no vhost at $SRC"; exit 1; }

echo "== origin $ORIGIN"
# Through this host's named, which needs a `home` static-stub in its internal
# view (ca/CLAUDE.md, and the comment in ca/scripts/install-ruby.sh).
addr=$(dig +short +time=3 +tries=1 @127.0.0.1 "$ORIGIN" A | tail -1)
[[ -n $addr ]] || { echo "!! $ORIGIN does not resolve via 127.0.0.1"; exit 1; }
echo "   resolves to $addr"

# The lab root, from this clone. The upstream's certificate chains to it, and
# nginx verifies that on every proxied connection.
install -m 0644 "$REPO/ca/rootca/certs/root.crt" "$ROOT_CA"
code=$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' --cacert "$ROOT_CA" \
         --resolve "$NAME:443:$addr" "https://$NAME/" 2>/dev/null) || code=000
[[ $code != 000 ]] || { echo "!! https://$NAME/ on $ORIGIN does not answer with a lab certificate"
                        echo "   check wg1, and that $ORIGIN's certificate carries $NAME"; exit 1; }
echo "   answers over TLS, verified against the lab root ($code)"

# A second server block claiming this name would be ours or a surprise.
for f in /etc/nginx/sites-enabled/*; do
  [[ -e $f && $(basename "$f") != "$NAME" ]] || continue
  if grep -qE "^[[:space:]]*server_name\b.*\b${NAME//./\\.}\b" "$f"; then
    echo "!! $f already claims $NAME - resolve that first"; exit 1
  fi
done

# The vhost reads the admin allow list the ruby.peetvandesande.com pages use.
[[ -s /etc/nginx/snippets/home-lan-allow.conf ]] || {
  echo "!! /etc/nginx/snippets/home-lan-allow.conf is missing"; exit 1; }

echo "== certificate"
if [[ -s /etc/letsencrypt/live/$NAME/fullchain.pem ]]; then
  echo "   already issued"
else
  # certonly with the nginx authenticator: it answers http-01 through the
  # running nginx by itself and edits no config, so the vhost below stays
  # exactly what is in git. The deploy hook is stored in the renewal config.
  certbot plugins --text 2>/dev/null | grep -q '^\* nginx' || {
    echo "!! certbot has no nginx plugin - apt install python3-certbot-nginx"; exit 1; }
  certbot certonly --nginx -n --keep-until-expiring -d "$NAME" \
    --deploy-hook "systemctl reload nginx"
fi

echo "== installing"
install -m 0644 "$SRC" "/etc/nginx/sites-available/$NAME"
ln -sfn "/etc/nginx/sites-available/$NAME" "/etc/nginx/sites-enabled/$NAME"
nginx -t
systemctl reload nginx

# ---------------------------------------------------------------- verify ---
# Pinned to ruby's public addresses, not by name and not via loopback: a
# server block listening on a specific address would win there over these
# wildcard ones, and only a request to the public address shows that.
echo "== verify"
fail=0
for a in "$PUBLIC4" "[$PUBLIC6]"; do
  code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
           --resolve "$NAME:443:${a//[\[\]]/}" "https://$NAME/" 2>/dev/null) || code=000
  case $code in
    000) echo "!! https://$NAME/ on $a: no TLS with a valid public certificate"; fail=1 ;;
    *)   echo "   https://$NAME/ on $a -> $code" ;;
  esac
  code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
           --resolve "$NAME:443:${a//[\[\]]/}" "https://$NAME/metrics" 2>/dev/null) || code=000
  [[ $code == 404 ]] && echo "   /metrics on $a -> 404" \
    || { echo "!! /metrics on $a -> $code, expected 404"; fail=1; }
done
if grep -qE 'proxy_pass https://\$' "/etc/nginx/sites-available/$NAME"; then
  echo "   proxied by name, resolved per request"
else
  echo "!! proxy_pass is not through a variable - see the vhost"; fail=1
fi
[[ $fail -eq 0 ]] || { echo "FAIL"; exit 1; }
echo "OK"
