# router

Reference for the **GL.iNet GL-BE14000** at **192.168.8.1**, which routes the
whole lab. Documentation only — see `CLAUDE.md` for why there is no config here.

| | |
|---|---|
| Firmware | GL.iNet 4.11.0, OpenWrt 25.12, kernel 6.12, aarch64 |
| Firewall | **fw4 / nftables** (`route_policy.global.use_fw4=1`) |
| dnsmasq | 2.92, with `nftset` |
| WAN | `eth1.832`, Orange XGS-PON; `2a01:cb1c:d:3500::/56` delegated – see `ORANGE.md` |

It replaced an Orange Livebox in October 2026, which is why the lab sits on
192.168.8.0/24 — the GL.iNet default, kept rather than fought.

The firewall engine matters more than it looks. Domain-based VPN routing is
implemented with dnsmasq's `nftset=` option, filling sets in the `inet
vpn_table` nftables table. Until the 4.11 upgrade (fw3, dnsmasq 2.85) it was
`ipset=` into legacy ipsets, and some things still carry that vocabulary:
`ipset list` on the device shows only `GL_MAC_BLOCK` now, and anything that
tests a set has to use `nft get element`. `dns/scripts/verify.sh` was caught by
that. `CLAUDE.md` invariant 9 is the other scar the upgrade left.

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

**Themis is advertised over IPv6**, since the IPv6 rollout: `ra_dns=1` with
`dhcp.lan.dns` naming Themis's ULA. It was `ra_dns=0` before, on the grounds
that dnsdist listened on IPv4 only and so an IPv6 resolver could only be a
bypass of Themis — the thing that would have been advertised was the *router*,
not a second resolver, and the fix was to advertise Themis instead of nothing.
See "Themis is advertised over IPv6 too" below. DHCPv6 stays disabled on the
LAN and `ra_flags` stays `none`; addressing is SLAAC from RA, which is all
`ip6=auto` on a container needs.

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

### Themis is advertised over IPv6 too (RDNSS)

Since the IPv6 rollout the RA carries Themis's ULA as a recursive DNS server,
so a client that prefers IPv6 for DNS reaches the same filtered resolver as one
using the DHCPv4 option. Before it, `ra_dns` was `0` and nothing was advertised
over IPv6 at all - deliberately, because the only thing that *could* have been
advertised was the router.

```sh
cp /etc/config/dhcp /etc/config/dhcp.bak-2026-10-24-ra-dns
uci add_list dhcp.lan.dns='fd33:5692:1834:1000:be24:11ff:feda:9b4b'   # themis
uci set dhcp.lan.ra_dns='1'
uci commit dhcp && /etc/init.d/odhcpd restart
```

Check it from a LAN client with `rdisc6 -1 br-lan` (or `ndisc6`), or just
`dig @fd33:5692:1834:1000:be24:11ff:feda:9b4b home.` to prove Themis answers
over IPv6 at all.

**Both lines go together, and the order matters more than it looks.** With
`ra_dns='1'` and `dhcp.lan.dns` unset, odhcpd falls back to advertising *the
router's own address* as RDNSS - which is a silent bypass of Themis's
filtering for every IPv6-capable client, arrived at by setting one option and
forgetting the other. See `CLAUDE.md` invariant 12.

The ULA, not the ISP prefix: `2a01:cb1c:d:3500::/64` renumbers with the lease,
and a resolver address that changes under the clients is worse than none.

### Outgoing DNS that is not Themis is rejected

Since 17 October 2026 the firewall rejects every way a LAN client could resolve
around Themis. The rules are plain `uci` firewall sections, so they show in
`uci show firewall | grep dns_egress` and survive a Keep-Settings upgrade; the
pre-change config is `/etc/config/firewall.bak-2026-10-17-dns-egress`.

| Section | Matches | Catches |
|---|---|---|
| `dns_egress_<zone>_853` | tcp/udp 853, any family | DoT and DoQ |
| `dns_egress_<zone>_53` | tcp/udp 53, any family | hard-coded plain resolvers (8.8.8.8 and friends) |
| `dns_egress_<zone>_doh4` / `_doh6` | tcp/udp 443 to set `doh_resolvers4` / `doh_resolvers6` | DoH to a hard-coded resolver address |

One of each for `lan`, `iot` and `guest`, with `dest '*'` so traffic bound for
the WireGuard zones is covered as well as `wan`. **The :53 and :853 rules are
family-agnostic and the DoH sets come in a v6 pair**, so enabling IPv6 DNS on
the LAN added no bypass to close - the rules caught v6 from the day they were
written, and the MAC exemptions work at the link layer and so exempt delphi
and hermes over either family. Target is `REJECT`, not
`DROP`: a client gets a TCP reset or ICMP unreachable at once and falls back to
the system resolver instead of hanging on a timeout. The rules sit at the top
of `forward_<zone>`, before the zone's accept jumps, so they cannot be undone
by an allow rule further down. LAN-to-LAN traffic is bridged and never enters
the forward chain, which is why Themis's own DoT and DoH on `.50` are
unaffected.

The two sets hold the well-known public resolvers — Cloudflare, Google, Quad9,
AdGuard, OpenDNS/Umbrella, NextDNS, Control D, Mullvad, dns0.eu, CleanBrowsing,
Comodo, Yandex — as single addresses or, where the provider has a dedicated
prefix, the prefix. They match on `dest_net` and only on :443, so ICMP to
1.1.1.1 and 8.8.8.8 still works; the blackbox exporter on .53 pings exactly
those for its `internet` probe. The names of DoH resolvers are blocked
separately, by the `doh` feed on Delphi, so the sets only have to catch
clients that skip the lookup. hagezi publishes a fuller IPv4 list
(`ips/doh.txt`, ~1400 entries) if the hand-picked set ever proves too small;
it would need `option loadfile` and something to refresh it.

**iCloud Private Relay is allowed through, on purpose.** Not by the router —
the relay runs on :443 to Apple addresses the sets do not list — but hagezi's
`doh` feed names its ingress (`mask.icloud.com`, `mask-h2.icloud.com`) and
Apple's oblivious-DoH resolver, and with those NXDOMAIN every Apple device
reported Private Relay as blocked. They are in Delphi's `allowlist.conf`. The
cost is real: a device with Private Relay on resolves and browses through
Apple, past Themis, which is the trade-off accepted for those devices.

**What the log showed in the first two days:** Home Assistant (.90) hammering
DoT to 1.1.1.1 and 1.0.0.1, thousands of rejects — HAOS's resolver falls back
to Cloudflare over TLS whenever it feels like it; switched off on 19 October
2026 with `ha dns options --fallback=false` (`homeassistant/CLAUDE.md`,
"Resolver"). A handful of clients tried 8.8.8.8 once and
fell back. Nothing has hit the resolver sets on :443.

**Two hosts are exempt from the :53 rule on `lan`, by MAC:** delphi (CT 106,
`BC:24:11:7D:3B:06`), the recursor, and hermes (VM 109,
`BC:24:11:1B:5D:14`), whose mailcow unbound also recurses. By MAC rather than
IP so both address families are covered in one line. Nothing is exempt from
:853 or the resolver sets.

Every rule logs at `10/minute` with its name as the prefix, so a device trying
to go around Themis shows up in Loki as `{host="router"} |= "Reject-Do"`, with
`SRC=` naming it. Recent hits also appear in `logread | grep Reject-Do`, and
the per-rule counters in `nft list chain inet fw4 forward_lan`.

```sh
# from any LAN host: refused at once, not a timeout
nc -vz -w3 1.1.1.1 853                      # Connection refused
dig @8.8.8.8 example.com +tcp +time=2       # connection refused
curl -m5 https://1.1.1.1/dns-query          # Connection refused
# still fine
ping -c1 1.1.1.1; dig @192.168.8.50 example.com
# macOS dig reports the UDP reject as a timeout; the router's counter shows the hit.
```

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

| Policy | Tunnel | Mark | Table | dnsmasq | Its resolver | nft set (`inet vpn_table`) |
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
   `nftset=/bbc.co.uk/4#inet#vpn_table#dst_net6611,6#inet#vpn_table#dst_net6611_6`
   lines, symlinked into each dnsmasq instance's `confdir`.
3. When dnsmasq answers one of those names it adds the returned addresses to
   that set.
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

### Metrics: two more forced-command keys

`router-metrics/` keeps two keys of its own here, both limited to a read-only
command: lenora's in `/etc/dropbear/authorized_keys` (`router-metrics@lenora`,
forced to `/usr/local/bin/router-metrics`) and the router's own
`/etc/dropbear/ont_metrics_key`, authorised on the ONT. Unlike the pieces
below, they need no pasting back: `router-metrics/scripts/deploy.sh` recreates
both and the script.

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

IPv4 only: the Proxmox SDN behind lenora has no IPv6 prefix at all, so there is
no equivalent rule to write. Unrelated to the LAN, which is dual-stack.

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
