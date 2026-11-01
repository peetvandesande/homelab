#!/usr/bin/env bash
# Is the Apple TV UK toggle wired up end to end? Read-only - it never flips
# the switch.
#
#   scripts/verify.sh
set -uo pipefail

ROUTER=192.168.8.1
LENORA=192.168.8.21
VMID=302
MAC=34:fd:6a:26:4c:83
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

r() { $SSH "root@$ROUTER" "$1" 2>&1; }

[[ $(r "uci show dhcp | grep -iA1 \"mac='$MAC'\" | grep -o \"ip='[0-9.]*'\"") == "ip='192.168.8.242'" ]] \
  && ok "$MAC reserved at 192.168.8.242" || fail "no reservation of $MAC at 192.168.8.242"
[[ $(r 'uci -q get route_policy.appletv_uk.via') == wgclient2 ]] \
  && ok "route_policy.appletv_uk goes via wgclient2" || fail "route_policy.appletv_uk missing or not via wgclient2"
[[ $(r '[ -x /usr/local/bin/appletv-uk ] && echo y') == y ]] \
  && ok "toggle installed on the router" || fail "/usr/local/bin/appletv-uk missing"
[[ $(r 'grep -c "^command=\"/usr/local/bin/appletv-uk\".* appletv-uk@homeassistant$" /etc/dropbear/authorized_keys') == 1 ]] \
  && ok "HA's key authorised, forced to the toggle" || fail "HA's key not authorised exactly once"

uci_state=$(r '/usr/local/bin/appletv-uk status')
rules=$(r 'nft list table inet vpn_table | grep -c "ether saddr @src_mac6612"')
if [[ $uci_state == on && $rules -gt 0 ]] || [[ $uci_state == off && $rules == 0 ]]; then
  ok "router is $uci_state and its nft rules agree"
else
  fail "router says $uci_state but has $rules nft rule(s) for the Apple TV"
fi

ha_state=$($SSH "root@$LENORA" "qm guest exec $VMID --timeout 30 -- docker exec homeassistant \
  ssh -i /config/.ssh/appletv_uk -o BatchMode=yes -o ConnectTimeout=5 \
  -o UserKnownHostsFile=/config/.ssh/known_hosts -o StrictHostKeyChecking=yes \
  root@$ROUTER status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())')
[[ $ha_state == "$uci_state" ]] \
  && ok "HA reaches the toggle and reads $ha_state" || fail "HA's ssh to the router returned '$ha_state'"

[[ $($SSH "root@$LENORA" "qm guest exec $VMID -- grep -c '^command_line: !include command_line.yaml' /mnt/data/supervisor/homeassistant/configuration.yaml" \
     | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())') == 1 ]] \
  && ok "configuration.yaml includes command_line.yaml" || fail "command_line.yaml is not included"

exit $(( fails > 0 ))
