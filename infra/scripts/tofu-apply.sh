#!/usr/bin/env bash
# Applies OpenTofu after a merge to main, and only when the merge changed infra/tofu,
# so a guest changed by hand is reported as drift rather than overwritten.
#
#   tofu-apply.sh <old-commit> <new-commit>         apply
#   tofu-apply.sh --plan <old-commit> <new-commit>  stop before applying
#
# Refuses any plan that deletes or replaces something: losing a guest takes a person.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"
log=$repo/infra/scripts/action-log

plan_only=0
[[ ${1:-} == --plan ]] && { plan_only=1; shift; }
old=${1:-}; new=${2:-}

if [[ -z $old || -z $new || $old =~ ^0+$ ]] || ! git rev-parse -q --verify "$old^{commit}" >/dev/null; then
  echo "no previous commit to compare with; nothing to apply"
  exit 0
fi
if git diff --quiet "$old" "$new" -- infra/tofu; then
  echo "== infra/tofu did not change; nothing to apply"
  exit 0
fi

export TOFU_TOKEN_NAME=PROXMOX_VE_API_TOKEN_APPLY
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

infra/scripts/tofu.sh init -input=false -lockfile=readonly >/dev/null
rc=0
infra/scripts/tofu.sh plan -input=false -detailed-exitcode -no-color -lock=false -out="$out/plan" || rc=$?
case $rc in
  0) echo "== nothing to apply"; exit 0 ;;
  2) ;;
  *) exit "$rc" ;;
esac

infra/scripts/tofu.sh show -json "$out/plan" > "$out/plan.json"
if ! python3 -I - "$out/plan.json" <<'PY'
import json, sys
changes = json.load(open(sys.argv[1])).get("resource_changes", [])
bad = [c["address"] for c in changes if "delete" in c["change"]["actions"]]
for address in bad:
    print(f"   would delete or replace: {address}")
sys.exit(1 if bad else 0)
PY
then
  echo "== refused: this plan deletes or replaces something, so a person has to apply it"
  if ((!plan_only)); then
    id=$("$log" start --action tofu:apply --targets proxmox)
    "$log" end "$id" --action tofu:apply refused --detail "plan deletes or replaces a resource"
  fi
  exit 1
fi

((plan_only)) && { echo "== plan is safe to apply; stopping here"; exit 0; }
# Nothing is applied unless the action can be recorded first.
id=$("$log" start --action tofu:apply --targets proxmox) \
  || { echo "== cannot write the action log; refusing to apply"; exit 1; }
if infra/scripts/tofu.sh apply -input=false -no-color "$out/plan"; then
  "$log" end "$id" --action tofu:apply succeeded
  echo "== applied"
else
  "$log" end "$id" --action tofu:apply failed
  exit 1
fi
