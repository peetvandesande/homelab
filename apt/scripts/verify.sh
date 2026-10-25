#!/usr/bin/env bash
# Assert the fleet is still patching itself: the configuration is the one this
# directory describes, the timers are enabled, and the metrics are fresh.
#
# Exit status is the number of failed checks.
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"

mapfile -t HOSTS < <(sed -n '/^FLEET=(/,/^)/p' ../ca/scripts/enrol.sh \
  | sed -n 's/^[[:space:]]*"\([0-9.][0-9.]*\)[[:space:]]\([a-z0-9-]*\).*/\1 \2/p')

echo "== configuration"
for entry in "${HOSTS[@]}"; do
  read -r ip name <<<"$entry"
  # Counted on the host, by LINE. The pattern itself contains commas
  # (origin=,codename=,label=), so anything that counts separators in the
  # joined value counts the value's own punctuation - which is how the first
  # version of this check managed to fail on a correct host.
  out=$($SSH "root@$ip" '
    echo "origin_n=$(apt-config dump --no-empty --format "%v%n" Unattended-Upgrade::Origins-Pattern | grep -c .)"
    echo "origin_sec=$(apt-config dump --no-empty --format "%v%n" Unattended-Upgrade::Origins-Pattern | grep -c -- "-security,label=Debian-Security")"
    echo "reboot=$(apt-config dump --format "%v" Unattended-Upgrade::Automatic-Reboot)"
    echo "kernels=$(apt-config dump --format "%v" Unattended-Upgrade::Remove-Unused-Kernel-Packages)"
    echo "periodic=$(apt-config dump --format "%v" APT::Periodic::Unattended-Upgrade)"
    echo "needrestart=$(needrestart -b 2>/dev/null >/dev/null && echo reports || echo missing)"
  ' 2>/dev/null) || { bad "$name ($ip) reachable" "ssh failed"; continue; }

  # Exactly one entry, and it must be the security one in its -security form.
  # More than one means the #clear in 52homelab-unattended-upgrades stopped
  # working and the package's own defaults are back alongside ours (CLAUDE.md
  # invariant 2); the bare ${distro_codename} form would match no archive at
  # all and patch nothing while looking right (invariant 3).
  n=$(sed -n 's/^origin_n=//p' <<<"$out")
  sec=$(sed -n 's/^origin_sec=//p' <<<"$out")
  if [[ "$n" == 1 && "$sec" == 1 ]]; then
    pass "$name: origins are Debian security only"
  else bad "$name: origins are Debian security only" \
      "$n entries, $sec of them the -security pattern (want 1 and 1)"; fi

  for key in reboot:false kernels:false periodic:1; do
    want=${key#*:}; k=${key%%:*}
    got=$(sed -n "s/^$k=//p" <<<"$out")
    if [[ "${got,,}" == "$want" ]]; then pass "$name: $k=$want"
    else bad "$name: $k=$want" "${got:-unset}"; fi
  done

  if [[ "$(sed -n 's/^needrestart=//p' <<<"$out")" == reports ]]; then
    pass "$name: needrestart installed"
  else bad "$name: needrestart installed" "not installed - run scripts/deploy.sh $ip"; fi
done

echo "== timers"
for entry in "${HOSTS[@]}"; do
  read -r ip name <<<"$entry"
  for t in apt-daily-upgrade.timer homelab-apt-textfile.timer; do
    if $SSH "root@$ip" "systemctl is-enabled --quiet $t" 2>/dev/null; then
      pass "$name: $t enabled"
    else bad "$name: $t enabled" "not enabled - run scripts/deploy.sh $ip"; fi
  done
done

echo "== metrics"
# The point of the whole directory: a host that has stopped patching must be
# visible. If this is stale, the grafana alerts that depend on it are blind.
now=$(date +%s)
for entry in "${HOSTS[@]}"; do
  read -r ip name <<<"$entry"
  prom=$($SSH "root@$ip" 'cat /var/lib/node_exporter/textfile/apt.prom' 2>/dev/null)
  if [[ -z "$prom" ]]; then
    bad "$name: apt.prom present" "missing - run scripts/deploy.sh $ip"; continue
  fi
  mtime=$($SSH "root@$ip" 'stat -c %Y /var/lib/node_exporter/textfile/apt.prom' 2>/dev/null)
  age=$(( now - ${mtime:-0} ))
  if (( age < 7200 )); then pass "$name: apt.prom fresh (${age}s old)"
  else bad "$name: apt.prom fresh" "${age}s old - the hourly timer is not running"; fi

  # Not this directory's business to fix, but it is the directory that claims
  # the fleet is patched, so you should see it here. Same reasoning as fleet/
  # invariant 4.
  sec=$(sed -n 's/^apt_upgrades_pending{origin="security"} //p' <<<"$prom")
  (( ${sec:-0} > 0 )) && warn "$name has $sec security update(s) pending" \
    "fine for a few hours; held back for a day means a package apt will not take unattended"
  nr=$(sed -n 's/^apt_services_need_restart //p' <<<"$prom")
  (( ${nr:-0} > 0 )) && warn "$name has $nr service(s) running on replaced libraries" \
    "patched but not effective until restarted: ssh root@$name needrestart -b"
  rb=$(sed -n 's/^apt_reboot_required //p' <<<"$prom")
  (( ${rb:-0} > 0 )) && warn "$name wants a reboot" "a kernel was replaced; nothing here will do it for you"

  last=$(sed -n 's/^apt_periodic_stamp_seconds{stamp="unattended-upgrades"} //p' <<<"$prom")
  if (( ${last:-0} > 0 && now - last < 172800 )); then
    pass "$name: unattended-upgrades ran $(( (now - last) / 3600 ))h ago"
  else
    bad "$name: unattended-upgrades ran in the last 48h" \
        "${last:-0} - never, if 0. journalctl -u apt-daily-upgrade"
  fi
done

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
