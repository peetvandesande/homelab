#!/usr/bin/env bash
# Give VPN clients the lab's own answer for git. and n8n.peetvandesande.com
# and n8n.sogode.com, as the LAN already gets, so they reach forgejo and moby
# over the tunnel instead of ruby's public vhosts - which refuse the n8n
# editors to them.
# Run on ruby AND on jennie, from the clone, with sudo:
#
#   cd ~/homelab && git pull && sudo wireguard/install-public-overrides.sh
#
# Installs the two zone files and this host's named.conf.local from the repo,
# and the sogode.com zone file, which already exists and gains n8n. The live
# named.conf.local must be the repo's copy, with or without these two zones,
# and the live sogode.com must be the repo's apart from its n8n records and
# serial: anything else is a change nobody recorded, and the script stops
# rather than overwrite it. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
ZONES=(git.peetvandesande.com n8n.peetvandesande.com)
UPDATED=sogode.com

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

# Both copies with these zone blocks taken out must match: the blocks
# themselves are this script's to replace.
strip() { awk -v names="${ZONES[*]}" '
  BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) drop["zone \"" a[i] "\" {"] = 1 }
  { key = $0; sub(/^[ \t]+/, "", key) }
  skip { if (key == "};") { skip = 0; blank = 1 } ; next }
  key in drop { skip = 1; next }
  blank && $0 == "" { blank = 0; next }
  { blank = 0; print }' "$1"; }
if cmp -s "$SRC" "$LIVE"; then
  echo "   named.conf.local is already the repo's"
elif cmp -s <(strip "$SRC") <(strip "$LIVE"); then
  echo "   named.conf.local differs from the repo only in these zones"
else
  echo "!! $LIVE differs from the repo by more than these zones:"
  diff -u "$LIVE" "$SRC" || true
  exit 1
fi

ZFILE=$self/../jennie/services/etc/bind/wireguard/$UPDATED
core() { grep -vE '; serial|^n8n[[:space:]]|n8n on moby' "$1"; }
if ! cmp -s <(core "$ZFILE") <(core "/etc/bind/wireguard/$UPDATED"); then
  echo "!! /etc/bind/wireguard/$UPDATED differs from the repo by more than its n8n records:"
  diff -u "/etc/bind/wireguard/$UPDATED" "$ZFILE" || true
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
named-checkzone -q "$UPDATED" "$ZFILE"
install -m 0644 -o root -g bind "$ZFILE" "/etc/bind/wireguard/$UPDATED"
rndc reload "$UPDATED" $view >/dev/null

echo "== verify, asking as a VPN client would"
fail=0
for z in "${ZONES[@]}" n8n.$UPDATED; do
  case $z in
    n8n.$UPDATED) want=$(awk '$1 == "n8n" && $3 == "IN" && $4 == "A" { print $5 }' "$ZFILE") ;;
    *)            want=$(awk '$4 == "A" { print $5 }' "/etc/bind/wireguard/$z") ;;
  esac
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
