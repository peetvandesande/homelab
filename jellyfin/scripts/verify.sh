#!/usr/bin/env bash
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.1.60

echo "== UI on plain HTTP 8096"
code=$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "http://$HOST:8096/System/Info/Public" 2>/dev/null || echo 000)
if [[ $code == 200 ]]; then pass "jellyfin /System/Info/Public (200 over plain HTTP)"
else bad "jellyfin /System/Info/Public over plain HTTP" "http=$code"; fi
loc=$(curl -sS --max-time 8 -o /dev/null -w '%{redirect_url}' "http://$HOST:8096/" 2>/dev/null)
if [[ $loc == https://* ]]; then bad "8096 does not redirect to HTTPS" "redirects to $loc - RequireHttps is on"
else pass "8096 does not redirect to HTTPS (${loc:-no redirect})"; fi

echo "== HTTPS on 8920 for Prometheus"
https_ok "jellyfin /System/Info/Public" "https://$HOST:8920/System/Info/Public"
# The check that actually caught the bug: .NET loads the PKCS#12 with
# X509Certificate2, which takes only the first certificate, so Kestrel served a
# bare leaf until the G3 intermediate was put in the system store.
chain_ok "jellyfin:8920" "$HOST:8920"
renewal_ok jellyfin "$HOST"

echo "== the PKCS#12 bundle tracks the certificate"
pfx=$(ssh -o BatchMode=yes root@$HOST "openssl pkcs12 -in /etc/homelab-tls/jellyfin.pfx -passin pass: -nokeys -clcerts 2>/dev/null | openssl x509 -noout -serial" 2>/dev/null | cut -d= -f2)
crt=$(ssh -o BatchMode=yes root@$HOST "openssl x509 -in /etc/homelab-tls/host.crt -noout -serial" 2>/dev/null | cut -d= -f2)
if [[ -n $pfx && $pfx == "$crt" ]]; then pass "jellyfin.pfx matches host.crt (serial $crt)"
else bad "jellyfin.pfx matches host.crt" "pfx=$pfx crt=$crt - the post-renew hook did not rebuild it"; fi

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
