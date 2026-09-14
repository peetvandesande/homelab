#!/usr/bin/env bash
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.1.61

echo "== navidrome HTTPS on 4533"
https_ok "navidrome /ping" "https://$HOST:4533/ping"
chain_ok "navidrome:4533" "$HOST:4533"
renewal_ok navidrome "$HOST"

echo "== plain HTTP must be gone"
# Navidrome swaps 4533 in place - there is no HTTP listener left, so any client
# still using http:// breaks rather than being redirected. That is intended.
no_plain_http "4533 refuses plain HTTP" "http://$HOST:4533/ping"

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
