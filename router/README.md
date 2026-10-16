# router

Reference for the **GL.iNet GL-BE14000** at **192.168.8.1**, which routes the
whole lab. Documentation only — see `CLAUDE.md` for why there is no config here.

| | |
|---|---|
| Firmware | GL.iNet 4.9.2, OpenWrt, kernel 5.4.281, aarch64 |
| Firewall | **fw3 / iptables + ipset** (`route_policy.global.use_fw4` unset) |
| dnsmasq | 2.85, compiled with `ipset` and **without `nftset`** |
| WAN | `eth1.832`, Orange XGS-PON; `2a01:cb1c:d:3500::/56` delegated – see `ORANGE.md` |

It replaced an Orange Livebox in October 2026, which is why the lab sits on
192.168.8.0/24 — the GL.iNet default, kept rather than fought.

The fw3/ipset detail matters more than it looks. Domain-based VPN routing is
implemented with dnsmasq's `ipset=` option, which needs legacy ipset; `nftset`
would need dnsmasq 2.90+ and this build has neither. So the whole mechanism is
tied to fw3, and anything that moves the device to fw4 changes it.

## Networks

| Name | Bridge | IPv4 | ULA | GUA |
|---|---|---|---|---|
| lan | `br-lan` | 192.168.8.1/24 | `fd33:5692:1834:1000::1/64` | `2a01:cb1c:d:3500::1/60` |
| iot | `br-iot` (VLAN 10) | 192.168.10.1/24 | `fd33:5692:1834:1001::1/64` | `2a01:cb1c:d:3510::1/60` |
| guest | `br-guest` | 192.168.9.0/24 | `fd33:5692:1834:1002::/64` | — |
| ONT mgmt | | 192.168.11.0/24 | | |

The guest network is **disabled** (`network.guest.disabled='1'`) and `br-guest`
does not exist; its settings are retained but it is not up. lan and iot are
live. Guest is VLAN 9, iot VLAN 10; iot arrives at lenora tagged on the same
uplink as the untagged LAN.

DHCP pools differ by network, which is easy to get wrong:

| Network | `start` | `limit` | Pool |
|---|---|---|---|
| lan | 100 | **140** | .100-.239 |
| guest | 100 | 150 | .100-.249 |
| iot | 100 | 150 | .100-.249 |

Lab hosts sit **below .100** as reservations keyed by MAC. On the LAN only,
**.240-.254** is for client devices that need a stable address without being lab
hosts — anything named in a DNS policy set, which stops working the moment its
address drifts. That is why the LAN pool alone was narrowed from 150: at
.100-.249 the range was inside it, and a reservation inside the pool races the
dynamic allocator. Narrow guest or iot the same way before reserving anything
above .239 there.

**No resolver is advertised over IPv6**, deliberately: `ra_dns=0`, DHCPv6
disabled on the LAN, `ra_flags=none`. dnsdist listens on IPv4 only, so an IPv6
resolver could only be a silent bypass of Themis. Addressing is still SLAAC from
RA, which is all `ip6=auto` on a container needs.

## DNS

```
dhcp.lan.dhcp_option      6,192.168.8.50   15,home     ← clients use Themis
dhcp.dnsinfra.dhcp_option 6,192.168.8.1                ← themis/delphi/pythia
dhcp.@dnsmasq[0].server   /home/192.168.8.52
                          /8.168.192.in-addr.arpa/192.168.8.52
gl-dns-v2.@dns[0].mode    auto                         ← upstream = Orange
```

The router's own dnsmasq is used by the three DNS containers (via the
`dnsinfra` tag) and by the router itself. Everything else on the LAN goes to
Themis. `server=/home/` lets the router resolve lab names even when the DNS
stack is down.

See `CLAUDE.md` invariants 1-4 for the settings that must not change.

## Time

```
dhcp.lan.dhcp_option      ... 42,192.168.8.1           ← advertise the router's NTP
chrony.@allow[0].interface lan
```

The router is the LAN's NTP server: chronyd, syncing upstream over NTS, serving
IPv4 and IPv6 on :123. `system.ntp.enable_server=0` is irrelevant – that is
sysntpd, which chrony replaces.

`allow lan` does not appear in `/var/etc/chrony.d/10-uci.conf`, which looks
like a bug but is not. chronyd starts before netifd has the LAN up, so the init
script renders no subnets; `/etc/hotplug.d/iface/20-chrony` adds them with
`chronyc allow` on each ifup. Test with `sntp 192.168.8.1`, not by reading the
config. Guest and IoT are not allowed, and their firewall zones reject input
anyway.

## Logs

```
system.@system[0].log_ip       192.168.8.56   ← Loki's Alloy, loki/root/etc/alloy/router.alloy
system.@system[0].log_port     1514
system.@system[0].log_proto    udp
system.@system[0].log_hostname router
system.@system[0].log_size     2048           ← KB of ring buffer, up from 512
```

`logread -f -r` forwards the whole ring buffer – kernel, hostapd, dnsmasq,
netifd – to Loki as RFC 3164 syslog. Query `{host="router"}`; `identifier` is
the syslog tag and `level` the severity, mapped to the journal's keywords.

- **UDP, not TCP.** Over TCP, logread ends a message with nothing Alloy's
  RFC 3164 parser takes as a frame boundary – not LF, and `log_trailer_null`'s
  NUL is not one either – so every line sat in Alloy's buffer until the next
  one arrived. A datagram is one message.
- **Not TLS.** logd cannot do it. The listener drops anything whose source is
  not 192.168.8.1.
- **Lines sent while Loki is down are lost there**, not queued. The 2 MB ring
  buffer – a few days – still has them on the router. `loki/scripts/verify.sh`
  fails if no router line has arrived in 15 minutes.

Keep Settings on a firmware upgrade keeps these; a factory reset does not.

## Routing-rule priority map

Identical shape for IPv4 and IPv6. `ip rule` / `ip -6 rule`:

| Priority | Rule | Owner |
|---|---|---|
| 0 | `local` | kernel |
| 800 | `lookup 9910 suppress_prefixlength 0` | GL |
| 6000 | `fwmark 0x1000` → 1001, `0x2000` → 1002, `0x8000` → main | GL |
| 9000 | marked, not 0 → `main` | GL |
| 9910 | marked, not 0 → `blackhole` | GL |
| 9920 | `iif br-lan` / `iif br-iot` → `blackhole` | GL |
| 10000 | from a tunnel's own address → its table | GL |
| **19000** | **site-to-site destinations → 1001/1002** | **ours** |
| 20000 | to a tunnel transit prefix → its table | GL |
| 32766 | `main` | kernel |
| 90047/90054 | `iif lo` → 1002 / 1001 | GL |

Table **9910** is a copy of `main`, rebuilt by `/usr/bin/rtp2.sh`
(`VPN_DIRECT_TABLE=9910`). It is not configured anywhere.

The two rules at 90047/90054 are why router-originated traffic to a tunnel's
remote subnets used to fail: they are checked *after* `32766 lookup main`, and
main carries `unreachable fd33:5692:1834::/48`. That is what the 19000 rules
fix.

## The two VPN tunnels

| Policy | Tunnel | Mark | Table | dnsmasq | Its resolver | ipset |
|---|---|---|---|---|---|---|
| Main VPN | `wgclient1` | `0x1000` | 1001 | `:2153` | 192.168.204.254 | `dst_net4399` |
| UK | `wgclient2` | `0x2000` | 1002 | `:2253` | 1.0.0.1 | `dst_net6611` |

Each tunnel gets its **own dnsmasq instance**, marked into that tunnel and
resolving through it. That is what makes a CDN hand back edges in the right
country, and it is why the DNS shunt on Themis targets `:2253` rather than
`:53`.

### Domain-based routing, and why Themis is involved

The router routes into a tunnel by **destination IP**:

1. The UI writes the policy's domains to `/etc/domain_mac_list/<set>`.
2. The firmware generates `/var/run/dnsmasq/via_domain` with
   `ipset=/bbc.co.uk/dst_net6611,dst_net6611_6` lines, symlinked into each
   dnsmasq instance's `confdir`.
3. When dnsmasq answers one of those names it adds the returned addresses to
   that ipset.
4. The policy rules match destination IPs in the set and apply the tunnel's
   mark.

**Nothing else fills those sets.** So a name under a domain policy has to be
answered by the router, or the routing silently never fires. Since the LAN
resolves through Themis, Themis shunts exactly those names to the tunnel's
dnsmasq instance — `dns/CLAUDE.md` invariant 11.

The same list carries bare destination IPs and prefixes alongside the domains;
those are set members the router adds directly and have no DNS dimension.
`dst_net4399` is *entirely* those — a site-to-site policy that generates no
dnsmasq lines at all.

### The two pieces of router-side state the DNS stack needs

Neither is in this repo, and a firmware upgrade can remove both. The
`vpn_domain_sync_success` alert in `grafana/` is what tells you. To restore:

```sh
# 1. the read-only dump the hourly sync on Themis consumes
cat > /usr/local/bin/vpn-policy-dump <<'EOF'
#!/bin/sh
# Read-only: the VPN policy, the per-tunnel dnsmasq ports, and the domain/IP
# lists. Consumed by vpn-domain-sync on themis (192.168.8.50).
uci show route_policy
uci show dhcp | grep -E "^dhcp\.[a-z0-9]+\.port="
for f in /etc/domain_mac_list/*; do
  [ -f "$f" ] || continue
  echo "==LIST==${f##*/}"
  cat "$f"
  echo
done
EOF
chmod 0755 /usr/local/bin/vpn-policy-dump

# 2. authorise Themis's key, forced to that one command - it gets no shell.
#    The public key is /etc/dnsdist/.ssh/router.pub on themis, and
#    dns/scripts/deploy.sh prints it if the sync cannot connect.
echo 'command="/usr/local/bin/vpn-policy-dump",no-port-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... vpn-domain-sync@themis' \
  >> /etc/dropbear/authorized_keys
```

## Site-to-site: the rules at 19000

Router-originated traffic to the tunnels' remote subnets did not work. Inbound
packets arrived fine, but the router's *reply* — sourced from its LAN address —
hit `32766 lookup main` before `90054 iif lo lookup 1001`, and main carries
`unreachable fd33:5692:1834::/48` for IPv6. IPv4 was worse: it had no
unreachable route, so replies went **out of the WAN**, handing RFC1918
destinations to Orange.

Fixed 2026-10-11 with four policy rules per family, named `s2s_*` in `uci`; a
fifth, for jennie's VPN clients, followed on 2026-10-16
(`network.bak-2026-10-16-jennie-clients`):

| Destination | Table | Tunnel |
|---|---|---|
| `192.168.204.0/24`, `fd33:5692:1834:204::/64` | 1001 | wgclient1 |
| `192.168.254.254`, `fd33:5692:1834:254::254` | 1001 | wgclient1 |
| `192.168.254.253`, `fd33:5692:1834:254::253` | 1001 | wgclient1 |
| `192.168.254.2`, `fd33:5692:1834:254::2` | 1002 | wgclient2 |
| `192.168.205.0/24`, `fd33:5692:1834:205::/64` | 1002 | wgclient2 |

Four things worth knowing about them:

- **`192.168.254.0/24` is split across both tunnels** — `.2` is via wgclient2,
  `.253`/`.254` via wgclient1. Hence `/32`s and `/128`s rather than a tidier
  `/24` or `/64`, which would send `.2` down the wrong tunnel. Do not
  "simplify" it.
- **The wgclient2 entries are standbys.** `192.168.254.2` and its v6 twin
  currently resolve via table 9910, because a copy exists in `main` that was
  added by hand at runtime — no `proto`, so not from `uci`. On the next reboot
  it goes, 9910's copy goes with it, and the 19000 rule takes over. Verified by
  deleting both copies: resolution moved to table 1002 and ping kept working.
- **IPv6 and IPv4 are not configured symmetrically, on purpose.** Table 1001's
  v6 side holds specific routes for the remote prefixes, from three `route6`
  sections. Its v4 side holds none — only `default dev wgclient1`, the transit
  `/30` and a `blackhole default metric 254`. The v4 rules work via that
  default, which also means they fail closed if the tunnel drops. There are no
  v4 `route` sections because none are needed, not because they were forgotten.
- **Do not try to put these routes in `main` instead.** `ip4table`/`ip6table`
  on the interface beats a per-route `table` option, so a `route6` with
  `table 'main'` lands in 1001 regardless. A policy rule pointing at the table
  that already holds the route is the mechanism that works.

Verify, from the router:

```sh
ip  rule | grep 19000        # five
ip -6 rule | grep 19000      # five
ip    route get 192.168.204.254          from 192.168.8.1
ip -6 route get fd33:5692:1834:204::254  from fd33:5692:1834:1000::1
ping -c2 -I 192.168.8.1 192.168.204.254
```

## Static route to lenora's SDN

`network.lab_sdn`: **`192.168.32.0/21` via 192.168.8.21** (lenora), on `lan`.
Added 2026-10-11 (`network.bak-2026-10-11-sdn-route`) so any Proxmox SDN
subnet carved out of that range is reachable from the LAN without a route per
subnet. lenora must forward (`net.ipv4.ip_forward=1`, already set), and an SDN
zone that SNATs makes the route unnecessary for outbound traffic but not for
reaching its guests.

It lands in `main` as `proto static` and is copied into table 9910 by
`rtp2.sh` (invariant 8), which is what makes clients under a VPN policy use it:
rule 800 consults 9910 before the 6000 `fwmark` rules can send them into a
tunnel. `rtp2.sh` only rebuilds 9910 on interface events, so a `network reload`
alone leaves the route out of 9910 until the next one. Check it:

```sh
ip route show table 9910 | grep 192.168.32
ip route get 192.168.33.1 from 192.168.8.150 iif br-lan mark 0x1000  # via 192.168.8.21, not wgclient1
```

IPv4 only. There is no IPv6 equivalent.

## Wi-Fi: clients that stop hearing multicast

The LAN SSID is an MLO set (`mld0`): `rai2` (5 GHz) and `rax2` (6 GHz), plus
the legacy `ra0`. A client on it can get into a state where it **receives no
group-addressed frames from the AP** – no ARP requests, no solicited-node or
all-nodes multicast – while unicast keeps working both ways. Found 2026-10-16
on mbp, on `rax2`.

It looks like a routing problem and is not one. Anything the client starts
works, because its own ARP request or NS carries its link-layer address and the
router learns it from that. What fails is the router having to *ask*: the
neighbour entry goes `INCOMPLETE`/`FAILED` and the packet is dropped. The first
sign was IPv6 from ruby to the laptop's ULA dying with `Address unreachable`
from the router, because return traffic over a tunnel is the case where the
router asks first.

Ruled out on 2026-10-16: routing (`ip -6 route get` is `dev br-lan`), odhcpd's
NDP proxy (`ndp=disabled`), the bridge's MLD snooping, and the MediaTek
driver's own snooping (`igmpsn_enable`; the laptop *was* listed as a member of
its groups, and `mwctl dev rax2 set multicast_snooping enable=0` made no
difference). Group rekey is off (`rekey_meth=DISABLE`), so it is not a rekey.
**Reconnecting the client's Wi-Fi fixes it**, which points at the client's group
key state for the MLO link. The root cause is not known.

To check a client, from the router – the neighbour state is the signal, so a
client that ignores ping still answers:

```sh
ip neigh del <ipv4> dev br-lan; ping -c2 -W1 <ipv4> >/dev/null; ip neigh show <ipv4> dev br-lan
# REACHABLE is fine; INCOMPLETE/FAILED on an awake client is this
```

## Installed but deliberately off

| Feature | State | Why |
|---|---|---|
| AdGuard Home | `enabled=0` | would take DNS away from dnsmasq and stop the ipsets filling — `CLAUDE.md` invariant 4 |
| Parental controls | `enable=0` | the lab's `kids` policy set does this, per device, with its own feeds |
| GL site-to-site | `enable=0` | the tunnels are plain WireGuard clients with hand-written policy |
| Force-DNS redirect | chain empty | would hijack clients' queries to Themis back to the router |
