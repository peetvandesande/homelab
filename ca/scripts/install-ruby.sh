#!/usr/bin/env bash
# Install the public ca.peetvandesande.com vhost on ruby. From the clone,
# with sudo:
#   sudo ~/homelab/ca/scripts/install-ruby.sh
# Safe to re-run. Modelled on homelab/outside/install.sh, which is the other
# thing in this repo that installs onto ruby from ruby's own clone.
#
# This is the only place the lab's /g2/ and /g3/ URLs are reachable from the
# internet. /g3/ is reverse-proxied to pistis over wg1; /g2/ is static, from
# this clone. See ca/ruby/etc/nginx/sites-available/ca.peetvandesande.com.
#
# RE-RUN THIS AFTER scripts/root-crl.sh. The /g2/ copy of the root CRL is the
# one thing here that is not proxied, so a regenerated CRL reaches pistis by
# deploy.sh and reaches ruby only by `git pull` and this script.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

NAME=ca.peetvandesande.com
ORIGIN=pistis.home       # proxied by name; see the vhost for why
G2DIR=/var/www/ca.g2

# Refuse to run on the wrong host. ruby is identified by dummy0, as in
# outside/install.sh - the public address is not a safe test, because the
# vhost would also "work" on jennie and serve nothing anyone can reach.
ip -4 addr show dev dummy0 2>/dev/null | grep -q "inet 192.168.254.254/" || {
  echo "not ruby: no 192.168.254.254 on dummy0"; exit 1; }

# The name has to resolve here before a vhost that proxies to it is worth
# enabling, and it resolves through this host's own named - which needs a
# `home` static-stub in its INTERNAL view, not just the wireguard one
# (wireguard/ruby/services/etc/bind/named.conf.local). Without it the query
# goes to the public root and NXDOMAINs.
echo "== origin $ORIGIN"
addr=$(dig +short +time=3 +tries=1 @127.0.0.1 "$ORIGIN" A | tail -1)
[[ -n $addr ]] || {
  echo "!! $ORIGIN does not resolve via 127.0.0.1"
  echo "   named's internal view needs: zone \"home\" { type static-stub;"
  echo "   server-addresses { 192.168.8.52; }; };"; exit 1; }
echo "   resolves to $addr"

# And it has to answer. A failure here is wg1 or pistis, not nginx - see
# wireguard/README.md.
curl -fsS --max-time 5 -o /dev/null -H "Host: $NAME" "http://$ORIGIN/healthz" || {
  echo "!! $ORIGIN is not answering on :80 - check wg1 and nginx on pistis"; exit 1; }
echo "   reachable"

# A second server block claiming this name would be ours or a surprise, and
# nginx resolves the collision silently with a warning. Fail loudly instead.
for f in /etc/nginx/sites-enabled/*; do
  [[ -e "$f" ]] || continue
  if [[ "$(basename "$f")" != "$NAME" ]] \
     && grep -qE "^[[:space:]]*server_name\b.*\b${NAME//./\\.}\b" "$f"; then
    echo "!! $f already claims $NAME - resolve that first"; exit 1
  fi
done

echo "== installing"
install -m 0644 ruby/etc/nginx/conf.d/ca-cache.conf /etc/nginx/conf.d/ca-cache.conf
install -m 0644 "ruby/etc/nginx/sites-available/$NAME" "/etc/nginx/sites-available/$NAME"
# nginx creates the cache directory itself, but as the master process's user;
# creating it here with the worker's own ownership keeps that off the boot path.
install -d -o www-data -g www-data -m 0700 /var/cache/nginx/ca

# The static /g2/ tree. Installed from rootca/ in this clone rather than
# checked in a second time under ruby/: the root CRL is already in the repo
# once, and two copies in git is the drift this is trying to avoid.
#
# root.crl is the ONLY file any pre-G3 certificate names. All three carry a
# crlDistributionPoints of http://ca.peetvandesande.com/g2/root.crl and no
# authorityInfoAccess at all, so there is no AIA object to publish.
# rootca/openssl.cnf mentions /g2/intermediate.crl and /g2/intermediate.crt,
# but in sections that were never applied to anything.
install -d -m 0755 "$G2DIR"
install -m 0644 rootca/crl/root.crl "$G2DIR/root.crl"
echo "   $G2DIR/root.crl"

ln -sfn "/etc/nginx/sites-available/$NAME" "/etc/nginx/sites-enabled/$NAME"

nginx -t
systemctl reload nginx

# ---------------------------------------------------------------- verify ---
# Through the local nginx with the Host header, not by name: this host
# resolves the name to its own public CNAME, so a probe by name would be a
# round trip through the internet to test a local config.
#
# curl is deliberately not given -L. A 200 here rather than a 301 is part of
# what is being asserted: these URLs must never redirect to https.
echo "== verify"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

fetch() { # fetch <path> <localname> <what>
  local code out="$tmp/$2"
  code=$(curl -s -o "$out" -m 10 -w '%{http_code}' \
         -H "Host: $NAME" "http://127.0.0.1$1") || code=000
  if [[ $code == 200 ]]; then
    echo "   $1 -> 200 ($3, $(stat -c%s "$out") bytes)"
  else
    echo "!! $1 -> $code, expected 200 ($3)"; fail=1; return 1
  fi
}

fetch /g3/root.crt         g3-root.crt   "G3 AIA caIssuers - the root"   || true
fetch /g3/root.crl         g3-root.crl   "G3 crlDistributionPoints"      || true
fetch /g3/intermediate.crt g3-int.crt    "the G3 intermediate itself"    || true
fetch /g3/chain.pem        g3-chain.pem  "root + G3, for the full chain" || true
fetch /g2/root.crl         g2-root.crl   "CDP of serials 1000-1002"      || true

# A CRL whose nextUpdate has passed is worse than no CRL: a client that
# honours the CDP rejects the whole chain. ca/CLAUDE.md invariant 6.
for g in g2 g3; do
  f="$tmp/$g-root.crl"
  [[ -s "$f" ]] || continue
  # PEM, not DER: rootca/crl/root.crl is published verbatim.
  nu=$(openssl crl -in "$f" -noout -nextupdate 2>/dev/null) || nu=""
  nu=${nu#nextUpdate=}
  if [[ -z $nu ]]; then
    echo "!! /$g/root.crl does not parse as a CRL"; fail=1
  elif [[ $(date -d "$nu" +%s 2>/dev/null || echo 0) -gt $(date +%s) ]]; then
    echo "   /$g/root.crl is current, nextUpdate $nu"
  else
    echo "!! /$g/root.crl has expired ($nu) - run ca/scripts/root-crl.sh"; fail=1
  fi
done

# The static copy must still be the same object as the proxied one: one root,
# one CRL. This is the check that catches a root-crl.sh that was deployed to
# pistis and never installed here.
if [[ -s "$tmp/g3-root.crl" && -s "$tmp/g2-root.crl" ]]; then
  if cmp -s "$tmp/g3-root.crl" "$tmp/g2-root.crl"; then
    echo "   /g2/root.crl is byte-identical to pistis's /g3/root.crl"
  else
    echo "!! /g2/root.crl has drifted from /g3/root.crl - one root must have"
    echo "   one CRL. git pull in this clone and re-run, or deploy.sh on pistis."
    fail=1
  fi
fi

# The proxy must be going through the name. A literal address in proxy_pass
# still works, so nothing else here would notice it being put back.
if grep -q 'proxy_pass http://\$pistis' "/etc/nginx/sites-available/$NAME"; then
  echo "   /g3/ is proxied by name, resolved per request"
else
  echo "!! /g3/ is not proxied through the \$pistis variable - a literal name"
  echo "   or address in proxy_pass resolves once at config load; see the vhost."
  fail=1
fi

[[ $fail -eq 0 ]] || { echo "FAIL"; exit 1; }
echo "OK - from outside: curl -I http://$NAME/g3/root.crl"
