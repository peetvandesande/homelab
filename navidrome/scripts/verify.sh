#!/usr/bin/env bash
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.1.61

http_ok() { # http_ok <label> <url>
  local code
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$2" 2>/dev/null || echo 000)
  if [[ $code == 200 ]]; then pass "$1 (200 over plain HTTP)"
  else bad "$1" "http=$code"; fi
}

echo "== navidrome plain HTTP on 4533"
http_ok "navidrome /ping" "http://$HOST:4533/ping"
http_ok "navidrome /metrics" "http://$HOST:4533/metrics"

echo "== 4533 no longer speaks TLS"
# curl prints 000 itself when the handshake fails, so no fallback echo here -
# with one, a failed handshake reads "000000" and never matches.
code=$(curl -sS --max-time 5 --cacert "$CA_ROOT" -o /dev/null -w '%{http_code}' "https://$HOST:4533/ping" 2>/dev/null)
if [[ ${code:-000} == 000 ]]; then pass "https://$HOST:4533 does not handshake"
else bad "https://$HOST:4533 does not handshake" "http=$code - TLSCert/TLSKey are still set"; fi

echo "== TLS leftovers removed"
if ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$HOST" 'test ! -e /etc/homelab-tls/post-renew.d/20-navidrome' 2>/dev/null; then
  pass "post-renew.d/20-navidrome is gone"
else bad "post-renew.d/20-navidrome is gone" "still present - it would restart navidrome on every renewal for nothing"; fi
# The host stays enrolled: node-exporter on :9100 still serves the certificate.
renewal_ok navidrome "$HOST"

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
