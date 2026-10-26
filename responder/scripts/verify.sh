#!/usr/bin/env bash
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
# shellcheck disable=SC1091
source secrets.env
HOST=192.168.8.24
R="ssh -o BatchMode=yes root@$HOST"
fail=${fail:-0}

echo "== service"
[[ $($R 'systemctl is-active responder') == active ]] && pass "responder active" || bad "responder active" "not active"

echo "== webhook"
code() { curl -sS --cacert "$CA_ROOT" -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null; }
URL="https://$HOST:9095/alert"
c=$(code -X POST -d '{}' "$URL"); [[ $c == 401 ]] && pass "no token is refused (401)" || bad "no token is refused" "$c"
c=$(code -X POST -H "Authorization: Bearer $RESPONDER_TOKEN" -d '{"alerts":[{"status":"firing","labels":{"alertname":"verify-not-allowlisted"}}]}' "$URL")
[[ $c == 202 ]] && pass "valid token accepted, unlisted alert ignored (202)" || bad "valid token accepted" "$c"

echo "== account"
$R 'runuser -u responder -- cat /home/peet/.bash_history' >/dev/null 2>&1 \
  && bad "responder cannot read /home/peet" "it can" || pass "responder cannot read /home/peet"
$R 'runuser -u responder -- sudo -n true' >/dev/null 2>&1 \
  && bad "responder has no sudo" "it has" || pass "responder has no sudo"
$R 'runuser -u responder -- curl -fsS --max-time 8 -o /dev/null https://prometheus.home:9090/-/healthy' \
  && pass "responder reaches Prometheus over verified TLS" || bad "responder reaches Prometheus" "failed"
if $R 'runuser -u responder -- env HOME=/var/lib/responder claude auth status' 2>&1 | grep -q '"loggedIn": true'; then
  pass "claude is logged in as responder"
else
  warn "claude is not logged in as responder" "sudo -iu responder, then: claude auth login"
fi

(( fail )) && { echo "== $fail failure(s)"; exit 1; } || echo "== ok"
