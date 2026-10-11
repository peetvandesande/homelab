#!/usr/bin/env bash
# Apply fleet-wide host hygiene: mask the units listed in ../masked-units on
# every enrolled host.
#
#   scripts/deploy.sh             the whole fleet
#   scripts/deploy.sh <ip>...     just those hosts (a newly built container)
#
# Idempotent, and safe to run at any point in a deploy order - it touches
# nothing any other stack owns.
set -euo pipefail

cd "$(dirname "$0")/.."
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

# The fleet is read out of ca/scripts/enrol.sh rather than copied here. That
# list is already duplicated in prometheus.yml's node job and node-exporter's
# FLEET, and a third copy to forget is not an improvement.
mapfile -t HOSTS < <(sed -n '/^FLEET=(/,/^)/p' ../ca/scripts/enrol.sh \
  | sed -n 's/^[[:space:]]*"\([0-9.][0-9.]*\)[[:space:]]\([a-z0-9-]*\).*/\1 \2/p')
(( ${#HOSTS[@]} )) || { echo "could not read FLEET from ca/scripts/enrol.sh"; exit 1; }

if (( $# )); then
  want=" $* "
  mapfile -t HOSTS < <(printf '%s\n' "${HOSTS[@]}" | awk -v w="$want" 'index(w, " " $1 " ")')
  (( ${#HOSTS[@]} )) || { echo "none of those hosts are in FLEET"; exit 1; }
fi

mapfile -t UNITS < <(grep -vE '^[[:space:]]*(#|$)' masked-units)
(( ${#UNITS[@]} )) || { echo "masked-units lists nothing"; exit 1; }
echo "== masking on ${#HOSTS[@]} host(s): ${UNITS[*]}"

rc=0
for entry in "${HOSTS[@]}"; do
  read -r ip name <<<"$entry"
  printf '  %-14s %-11s ' "$ip" "$name"
  # reset-failed after mask: masking does not clear an already-failed state, and
  # a unit left failed is exactly what the grafana alert fires on.
  out=$($SSH "root@$ip" "
    for u in ${UNITS[*]}; do
      systemctl mask \"\$u\" >/dev/null 2>&1 || true
      systemctl reset-failed \"\$u\" >/dev/null 2>&1 || true
      [ \"\$(systemctl show \"\$u\" -p LoadState --value)\" = masked ] || echo \"NOT-MASKED:\$u\"
    done
  " 2>&1) || { echo "UNREACHABLE"; rc=1; continue; }

  # Deliberately not reporting units that are masked but unlisted. A Debian
  # LXC starts with a dozen - cryptdisks, hwclock, x11-common, sys-kernel-*,
  # journald-audit, plus zfs-* and nfs-common on lenora - so that set is
  # pre-existing baseline rather than drift, and printing it on every run
  # only teaches you to stop reading the output.
  if grep -q NOT-MASKED <<<"$out"; then
    echo "FAILED: $(grep -o 'NOT-MASKED:.*' <<<"$out" | tr '\n' ' ')"; rc=1
  else
    echo "ok"
  fi
done

echo
(( rc )) && echo "== some hosts did not apply - see above" || echo "== fleet hygiene applied"
exit $rc
