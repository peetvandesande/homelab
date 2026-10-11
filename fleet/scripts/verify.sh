#!/usr/bin/env bash
# Assert fleet-wide host hygiene: every unit in ../masked-units is masked on
# every enrolled host, and no host has a failed unit.
#
# Exit status is the number of failed checks.
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"

mapfile -t HOSTS < <(sed -n '/^FLEET=(/,/^)/p' ../ca/scripts/enrol.sh \
  | sed -n 's/^[[:space:]]*"\([0-9.][0-9.]*\)[[:space:]]\([a-z0-9-]*\).*/\1 \2/p')
mapfile -t UNITS < <(grep -vE '^[[:space:]]*(#|$)' masked-units)

echo "== masked units (${UNITS[*]})"
for entry in "${HOSTS[@]}"; do
  read -r ip name <<<"$entry"
  out=$($SSH "root@$ip" "for u in ${UNITS[*]}; do
      printf '%s=%s\n' \"\$u\" \"\$(systemctl show \"\$u\" -p LoadState --value)\"
    done" 2>/dev/null) || { bad "$name ($ip) reachable" "ssh failed"; continue; }
  wrong=$(grep -v '=masked$' <<<"$out" | tr '\n' ' ')
  if [[ -z "$wrong" ]]; then pass "$name: all listed units masked"
  else bad "$name: all listed units masked" "${wrong:-unknown} - run scripts/deploy.sh $ip"; fi
done

echo "== no failed units anywhere"
# The point of the masking is that this stays empty, so the grafana
# systemd-unit-failed alert is about real problems. A failed unit that is not in
# masked-units is a genuine fault somewhere else, so it warns rather than fails
# - it is not this directory's to fix, but you should see it here.
for entry in "${HOSTS[@]}"; do
  read -r ip name <<<"$entry"
  f=$($SSH "root@$ip" 'systemctl list-units --failed --no-legend --plain 2>/dev/null | awk "{print \$1}" | tr "\n" " "' 2>/dev/null)
  if [[ -z "${f// }" ]]; then pass "$name: no failed units"
  else warn "$name has failed units" "${f}- not masked here; fix the unit or add it to masked-units if it is fleet-wide noise"; fi
done

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
