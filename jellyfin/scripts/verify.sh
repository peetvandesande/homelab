#!/usr/bin/env bash
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.8.60

echo "== UI and /metrics on plain HTTP 8096"
code=$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "http://$HOST:8096/System/Info/Public" 2>/dev/null || echo 000)
if [[ $code == 200 ]]; then pass "jellyfin /System/Info/Public (200 over plain HTTP)"
else bad "jellyfin /System/Info/Public over plain HTTP" "http=$code"; fi
code=$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "http://$HOST:8096/metrics" 2>/dev/null || echo 000)
if [[ $code == 200 ]]; then pass "jellyfin /metrics (200 over plain HTTP)"
else bad "jellyfin /metrics over plain HTTP" "http=$code"; fi
loc=$(curl -sS --max-time 8 -o /dev/null -w '%{redirect_url}' "http://$HOST:8096/" 2>/dev/null)
if [[ $loc == https://* ]]; then bad "8096 does not redirect to HTTPS" "redirects to $loc - RequireHttps is on"
else pass "8096 does not redirect to HTTPS (${loc:-no redirect})"; fi

echo "== no HTTPS listener"
if curl -sk --max-time 5 -o /dev/null "https://$HOST:8920/" 2>/dev/null; then bad "8920 is closed" "something still answers HTTPS - EnableHttps is on"
else pass "8920 is closed"; fi
renewal_ok jellyfin "$HOST"

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
