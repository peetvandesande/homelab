#!/usr/bin/env bash
# Writes a test entry to the action log and reads it back from Loki. Run on talos,
# as root or the runner. Exits non-zero if the entry does not arrive within two minutes.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
log=$repo/infra/scripts/action-log
export ACTION_ACTOR=verify ACTION_TRIGGER=verify-action-log
ACTION_COMMIT=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)
export ACTION_COMMIT

id=$("$log" start --action test:verify --targets "$(hostname)")
"$log" end "$id" --action test:verify succeeded

for _ in $(seq 1 24); do
  count=$(curl -sS -G --cacert /etc/homelab-tls/root_ca.crt \
    https://loki.home:3100/loki/api/v1/query_range \
    --data-urlencode "query={identifier=\"homelab-action\"} |= \"$id\"" \
    | python3 -I -c 'import json,sys; print(sum(len(s["values"]) for s in json.load(sys.stdin)["data"]["result"]))')
  if [[ $count == 2 ]]; then
    echo "OK: both lines of $id reached Loki"
    exit 0
  fi
  sleep 5
done
echo "FAIL: $id has $count of 2 lines in Loki"
exit 1
