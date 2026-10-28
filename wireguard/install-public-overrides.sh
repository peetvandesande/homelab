#!/usr/bin/env bash
# Give VPN clients the lab's own answer for git. and n8n.peetvandesande.com,
# as the LAN already gets, so they reach forgejo and moby over the tunnel
# instead of ruby's public vhost - which refuses the n8n editor to them.
# Run on ruby AND on jennie, from the clone, with sudo:
#
#   cd ~/homelab && git pull && sudo wireguard/install-public-overrides.sh
#
# Installs the two zone files and this host's named.conf.local from the repo.
# The live named.conf.local must be the repo's copy, with or without these two
# zones: anything else is a change nobody recorded, and the script stops
# rather than overwrite it. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
ZONES=(git.peetvandesande.com n8n.peetvandesande.com)

if ip -4 addr show dev dummy0 | grep -q "inet 192.168.254.254/"; then
  self=ruby; ns=192.168.204.254; view="IN wireguard"
elif ip -4 addr show dev dummy0 | grep -q "inet 192.168.254.2/"; then
  self=jennie; ns=192.168.205.254; view=""
else
  echo "neither ruby nor jennie: no 192.168.254.254 or .2 on dummy0"; exit 1
fi
SRC=$self/services/etc/bind/named.conf.local
LIVE=/etc/bind/named.conf.local
echo "== $self"

# The repo's copy with the new zone blocks taken out: what the live file
# should be if this has never run.
without=$(awk -v names="${ZONES[*]}" '
  BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) drop["zone \"" a[i] "\" {"] = 1 }
  { key = $0; sub(/^[ \t]+/, "", key) }
  skip { if (key == "};") { skip = 0; blank = 1 } ; next }
  key in drop { skip = 1; next }
  blank && $0 == "" { blank = 0; next }
  { blank = 0; print }' "$SRC")
if cmp -s "$SRC" "$LIVE"; then
  echo "   named.conf.local is already the repo's"
elif cmp -s <(printf '%s\n' "$without") "$LIVE"; then
  echo "   named.conf.local is the repo's, without the new zones"
else
  echo "!! $LIVE differs from the repo by more than these zones:"
  diff -u "$LIVE" "$SRC" || true
  exit 1
fi

for z in "${ZONES[@]}"; do
  install -m 0644 -o root -g bind "$self/../jennie/services/etc/bind/wireguard/$z" "/etc/bind/wireguard/$z"
  named-checkzone -q "$z" "/etc/bind/wireguard/$z"
done
bak=$LIVE.bak-$(date +%F-%H%M%S)
cp -p "$LIVE" "$bak"
install -m 0644 -o root -g bind "$SRC" "$LIVE"
named-checkconf -z >/dev/null || { echo "!! named-checkconf failed - restoring $bak"; cp -p "$bak" "$LIVE"; exit 1; }
rndc reconfig
cmp -s "$bak" "$LIVE" && rm -f "$bak"

echo "== verify, asking as a VPN client would"
fail=0
for z in "${ZONES[@]}"; do
  want=$(awk '$4 == "A" { print $5 }' "/etc/bind/wireguard/$z")
  for _ in {1..5}; do
    got=$(dig +short +time=2 +tries=1 -b "$ns" @"$ns" "$z" A | tail -1)
    [[ $got == "$want" ]] && break
    sleep 1
  done
  [[ $got == "$want" ]] && echo "   $z -> $got" || { echo "!! $z -> ${got:-nothing}, want $want"; fail=1; }
done
[[ -n $view ]] && rndc zonestatus "${ZONES[0]}" $view >/dev/null && echo "   loaded in the wireguard view"
[[ $fail -eq 0 ]] || { echo "FAIL"; exit 1; }
echo "OK"
