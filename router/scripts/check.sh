#!/usr/bin/env bash
# Read-only: compares the live router with the settings the lab depends on, listed
# in router/CLAUDE.md. Changes nothing, so it is safe to run at any time.
set -uo pipefail
ROUTER=192.168.8.1
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$ROUTER")
fail=0
pass() { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
get() { "${SSH[@]}" "uci -q get '$1'" 2>/dev/null; }
is() { local got; got=$(get "$2"); [[ $got == "$3" ]] && pass "$1" || bad "$1" "${got:-unset}"; }
has() { local got; got=$(get "$2"); [[ " $got " == *" $3 "* ]] && pass "$1" || bad "$1" "${got:-unset}"; }
off() { local got; got=$(get "$2"); [[ -z $got || $got == 0 ]] && pass "$1" || bad "$1" "$got"; }

echo "== DNS for clients"
has "clients are given Themis" dhcp.lan.dhcp_option 6,192.168.8.50
has "clients are given the home domain" dhcp.lan.dhcp_option 15,home
is "IPv6 clients are told to use a named resolver" dhcp.lan.ra_dns 1
[[ -n $(get dhcp.lan.dns) ]] && pass "and that resolver is set" || bad "and that resolver is set" unset

echo "== DNS loops and bypasses that must stay absent"
off "the main dnsmasq keeps its upstream" 'dhcp.@dnsmasq[0].noresolv'
servers=$(get 'dhcp.@dnsmasq[0].server')
[[ " $servers " != *" 192.168.8.50 "* ]] && pass "the router does not forward to Themis" || bad "the router does not forward to Themis" "$servers"
[[ " $servers " == *" /home/192.168.8.52 "* ]] && pass "the router resolves lab names at Pythia" || bad "the router resolves lab names at Pythia" "$servers"
off "AdGuard Home is off" adguardhome.config.enabled
off "the legacy TCP drop rule is off" firewall.tcp_dns_leak_drop.enabled

echo "== Addressing"
is "the DHCP pool starts at .100" dhcp.lan.start 100
is "the DHCP pool has 140 addresses" dhcp.lan.limit 140
is "the DNS stack stays on the router" dhcp.dnsinfra.dhcp_option 6,192.168.8.1

echo "== Egress"
is "non-Themis DNS is rejected, not dropped" firewall.dns_egress_lan_53.target REJECT
macs=$(get firewall.dns_egress_lan_53.src_mac)
[[ -n $macs ]] && pass "delphi and hermes are exempted by MAC" || bad "delphi and hermes are exempted by MAC" unset

echo "== Files the lab installed"
for f in /etc/nftables.d/20-orange-pcp.nft /usr/local/bin/vpn-policy-dump /usr/local/bin/router-metrics \
         /usr/local/bin/wan-watchdog /usr/local/bin/wifi-watchdog; do
  "${SSH[@]}" "test -e $f" && pass "$f" || bad "$f" missing
done
echo
if ((fail)); then echo "$fail check(s) failed"; exit 1; fi
echo "all checks passed"
