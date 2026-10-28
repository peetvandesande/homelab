#!/usr/bin/env bash
# Turn on unattended security upgrades across the whole fleet, and the metrics
# that say whether they are still happening.
#
# One service on fourteen hosts, so one directory rather than fourteen copies -
# the same shape as node-exporter/ and alloy/, and the reason this is not in
# fleet/, which asserts state and has nothing to push.
#
#   scripts/deploy.sh            the whole fleet
#   scripts/deploy.sh <ip>...    just those hosts (a new container)
#
# Independent of every other deploy order, with one dependency: the textfile
# drop-box, which node-exporter/scripts/deploy.sh creates. Deploy refuses
# without it rather than publishing metrics nothing will scrape.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh

# The fleet is read out of ca/scripts/enrol.sh rather than copied here - the
# same reasoning as fleet/scripts/deploy.sh, invariant 1 there.
mapfile -t HOSTS < <(sed -n '/^FLEET=(/,/^)/p' ../ca/scripts/enrol.sh \
  | sed -n 's/^[[:space:]]*"\([0-9.][0-9.]*\)[[:space:]]\([a-z0-9-]*\).*/\1 \2/p')
(( ${#HOSTS[@]} )) || { echo "could not read FLEET from ca/scripts/enrol.sh"; exit 1; }

if (( $# )); then
  want=" $* "
  mapfile -t HOSTS < <(printf '%s\n' "${HOSTS[@]}" | awk -v w="$want" 'index(w, " " $1 " ")')
  (( ${#HOSTS[@]} )) || { echo "none of those hosts are in FLEET"; exit 1; }
fi

for entry in "${HOSTS[@]}"; do
  read -r ip name <<<"$entry"
  echo "-------------------------------------------------- $ip $name"
  push "$ip" root
  $SSH "root@$ip" '
    set -e
    test -d /var/lib/node_exporter/textfile || {
      echo "   no textfile drop-box - run node-exporter/scripts/deploy.sh first"; exit 1; }

    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    apt-get -qq -y install unattended-upgrades needrestart >/dev/null

    # Assert the #clear worked. apt config lists APPEND, so without it the
    # packages default origins would still be active alongside ours and this
    # would report more than one entry - see CLAUDE.md invariant 2.
    n=$(apt-config dump --no-empty --format "%v%n" Unattended-Upgrade::Origins-Pattern | grep -c .)
    [ "$n" = 1 ] || { echo "   Origins-Pattern has $n entries, expected 1 - the #clear is not working"; exit 1; }
    # Must be the -security form: ${distro_codename} alone does not match an
    # archive whose Codename is <codename>-security, and would patch nothing.
    apt-config dump --no-empty --format "%v%n" Unattended-Upgrade::Origins-Pattern \
      | grep -q -- "-security,label=Debian-Security" \
      || { echo "   Origins-Pattern is not the Debian -security pattern"; exit 1; }

    # Prove the configuration parses and resolves to a package set, rather than
    # trusting that it validated. --dry-run installs nothing - but it DOES
    # advance /var/lib/apt/periodic/unattended-upgrades-stamp, which is the
    # metric grafana reads to decide whether a host is still patching. So the
    # stamp is put back: a deploy must not reset that clock, or deploying is
    # enough to make a host that has never patched look freshly patched.
    stamp=/var/lib/apt/periodic/unattended-upgrades-stamp
    prev=$(stat -c %Y "$stamp" 2>/dev/null || true)
    unattended-upgrade --dry-run >/dev/null 2>&1 \
      || { echo "   unattended-upgrade --dry-run failed"; exit 1; }
    if [ -n "$prev" ]; then touch -d "@$prev" "$stamp"; else rm -f "$stamp"; fi

    # Shipped enabled by the apt package, but assert rather than assume: these
    # two timers are the whole mechanism.
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1

    systemctl daemon-reload
    systemctl enable --now homelab-apt-textfile.timer >/dev/null 2>&1
    systemctl start homelab-apt-textfile.service
    test -s /var/lib/node_exporter/textfile/apt.prom \
      || { echo "   apt.prom was not written"; exit 1; }
    echo "   $(sed -n "s/^apt_upgrades_pending{origin=\"security\"} //p" \
          /var/lib/node_exporter/textfile/apt.prom) security update(s) pending"
  '
done

echo
echo "== unattended security upgrades on ${#HOSTS[@]} host(s), metrics publishing"
echo "   alerts live in grafana/ group 'apt'. Deploy grafana/ only once EVERY host"
echo "   publishes: apt-not-patching treats NoData as alerting, so provisioning it"
echo "   early fires on the phone for every host still missing the metric."
