#!/usr/bin/env bash
# Checks the runbook engine on lexie, and proves an alert reaches the action log.
cd "$(dirname "$0")/.." || exit 1
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
# shellcheck disable=SC1091
source ../../homelab-private/responder/secrets.env
HOST=192.168.8.24
R="ssh -n -o BatchMode=yes root@$HOST"
URL="https://$HOST:9096/alert"
code() { curl -sS --cacert "$CA_ROOT" -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null; }

echo "== service"
[[ $($R 'systemctl is-active runbook-engine') == active ]] && pass "engine active" || bad "engine active" "not active"

echo "== webhook"
c=$(code -X POST -d '{}' "$URL"); [[ $c == 401 ]] && pass "no token is refused (401)" || bad "no token is refused" "$c"
c=$(code -X POST -H "Authorization: Bearer wrong" -d '{}' "$URL"); [[ $c == 401 ]] && pass "wrong token is refused (401)" || bad "wrong token is refused" "$c"

echo "== account"
$R 'runuser -u runbook -- sudo -n true' >/dev/null 2>&1 && bad "runbook has no sudo" "it has" || pass "runbook has no sudo"
$R 'test ! -e /var/lib/runbook/.ssh' && pass "runbook has no SSH key" || bad "runbook has no SSH key" "it has"

echo "== end to end"
fp=$(openssl rand -hex 8)
body=$(printf '{"alerts":[{"status":"firing","fingerprint":"%s","labels":{"alertname":"Runbook engine test"}}]}' "$fp")
c=$(printf 'header = "Authorization: Bearer %s"\n' "$RUNBOOK_TOKEN" | curl -sS --cacert "$CA_ROOT" -K - -o /dev/null -w '%{http_code}' --max-time 5 -X POST -d "$body" "$URL" 2>/dev/null)
[[ $c == 202 ]] && pass "test alert accepted (202)" || bad "test alert accepted" "$c"
found=""
for _ in $(seq 1 24); do
  found=$(curl -sS -G --cacert "$CA_ROOT" https://loki.home:3100/loki/api/v1/query_range \
    --data-urlencode "query={identifier=\"homelab-action\"} |= \"$fp\" |= \"\\\"outcome\\\": \\\"shadow\\\"\"" \
    | python3 -I -c 'import json,sys; print(sum(len(s["values"]) for s in json.load(sys.stdin)["data"]["result"]))')
  [[ $found == 1 ]] && break
  sleep 5
done
[[ $found == 1 ]] && pass "shadow outcome reached Loki" || bad "shadow outcome reached Loki" "${found:-nothing}"

if ((fail)); then echo "== $fail failure(s)"; exit 1; fi
echo "== ok"
