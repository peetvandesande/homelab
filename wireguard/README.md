# WireGuard: ruby, jennie and home

How the WireGuard network between **ruby**, **jennie** and the **home** router is built, and why. This file explains the design; it isn't a runbook. The rollout's steps, what's still open, and rollback are in [TASKS.md](TASKS.md).

Status as of 2026-10-16: everything described here is live, except the reverse zones in ruby's `internal` view (TASKS.md follow-ups).

***

## Topology

```
   mba, mbp, iphone-peet                                     mba, mbp, iphone-peet
      (road warriors)                                          (when ruby is down)
                  │                                                     │
                  │ wg0 :51820                               wg0 :51820 │
                  ▼                                                     ▼
   ┌────────────────────────────┐   wg2 :51822 (IPv6)    ┌────────────────────────────┐
   │            ruby            │◄──────────────────────►│           jennie           │
   │ 192.168.254.254, .253      │  172.31.1.4/30         │ 192.168.254.2              │
   │ fd33:5692:1834:254::254    │  ff02::/64             │ fd33:5692:1834:254::2      │
   │ fd33:5692:1834:254::253    │                        │ internet exit (NAT44/66)   │
   │                            │                        │ clients 192.168.205.0/24   │
   └────────────────────────────┘                        └────────────────────────────┘
                  ▲                                                     ▲
                  │ wg1 :51821 (IPv6)                wg3 :51823 (IPv6)  │
                  │ 172.31.1.0/30, ff01::/64  172.31.1.8/30, ff03::/64  │
                  │                                                     │
                  └──────────────────── home router ────────────────────┘
                        192.168.8.0/21, fd33:5692:1834:1000::/56
                        (+ the ISP's own IPv6 ranges)
```

Three sites in a triangle, each pair with its own tunnel, plus the clients on ruby. The same clients also have a second tunnel to jennie, so they keep working if ruby is down (see [Clients on jennie](#clients-on-jennie)):

| Traffic                     | Path                     |
|-----------------------------|--------------------------|
| clients ↔ home LANs         | wg0 → ruby → wg1         |
| clients ↔ jennie            | wg0 → ruby → wg2         |
| ruby ↔ jennie               | wg2                      |
| ruby ↔ home LANs            | wg1                      |
| jennie ↔ home LANs          | wg3, direct (not via ruby) |
| clients → IPv6 internet     | wg0 → ruby → wg2 → jennie → internet (NAT66) |
| clients → IPv4 internet     | wg0 → ruby → internet (default), or via jennie per client (opt-in) |
| home → internet via jennie  | wg3 → jennie → internet, for whatever the router chooses (e.g. the laptop, or BBC) |
| jennie's clients ↔ home LANs | wg0 → jennie → wg3 |
| jennie's clients ↔ ruby     | wg0 → jennie → wg2 |
| jennie's clients → internet | wg0 → jennie → internet (NAT44/NAT66) |

All three site-to-site tunnels run over IPv6:

| Tunnel | Who dials             | Endpoint                               |
|--------|-----------------------|----------------------------------------|
| wg1    | home → ruby      | `[2001:41d0:305:2100::1:3a0e]:51821`   |
| wg2    | both ends set endpoints, either can start | ruby → `[2001:41d0:801:2000::180f]:51822`, jennie → `[2001:41d0:305:2100::1:3a0e]:51822` |
| wg3    | home → jennie    | `[2001:41d0:801:2000::180f]:51823`     |

Routing is static. Each tunnel only carries traffic for the networks directly behind its far end, and there's **no failover**: if wg3 is down, jennie and the home LANs can't reach each other (traffic is not rerouted via ruby). Separate interfaces per link are what would let dynamic routing (OSPF/BGP with BIRD or FRR) do that later.

There is no filtering inside the VPN.

**jennie is the VPN's internet exit** (see [Internet exits](#internet-exits)). It forwards and NATs traffic from ruby's clients and from home, but it's never a path *between* sites. It's also the clients' fallback server: its own `wg0` gives them home, ruby and the internet without going through ruby (see [Clients on jennie](#clients-on-jennie)).

### Interface naming

Each tunnel uses the **same interface name and port on both ends**, so `wg3` means the jennie–home tunnel wherever you see it. `wg0` is the exception: it means *a server's client tunnel*, on 51820, and ruby's and jennie's are separate tunnels with separate ranges:

| Host      | Interfaces          |
|-----------|---------------------|
| ruby      | wg0, wg1, wg2       |
| jennie    | wg0, wg2, wg3       |
| home | wg1 (`wgclient1`), wg3 (`wgclient2`) |

### Netplan, not wg-quick

ruby and jennie configure their networks with netplan, so every WireGuard interface is a netplan `tunnels:` entry of `mode: wireguard`, rendered by systemd-networkd. Things that differ from wg-quick:

- **Routes are explicit.** networkd doesn't add routes for `AllowedIPs`, so each YAML file lists the routes for the far end's networks under `routes:`. The transit `/30` and `/64` come from the interface addresses.
- **No PostUp/PostDown hooks.** Firewalls and NAT live in each host's `/etc/nftables.conf` (see [Firewall on ruby](#firewall-on-ruby)). The one thing that can't go there, an exception in Docker's IPv6 forward chain, is a small systemd unit, `wg-docker-user.service`.
- **Keys are inline in the YAML.** Files in `/etc/netplan` must be mode `600`; networkd's generated copies in `/run/systemd/network` are `640 root:systemd-network`. The repo's copies hold `<placeholders>` only.
- **New interfaces come up with `networkctl reload`**, which leaves existing ones alone. `netplan apply` also works, but it reconfigures every netplan-managed interface, ens3 included.
- **Changes to an existing tunnel** don't always get applied by `networkctl reload`. See [Day-to-day](#day-to-day).

**Forwarding is owned by networkd**, set globally for both families in `networkd-forwarding.conf` on each server (needs systemd ≥ 256). On ruby it used to be IPv4 from a per-interface drop-in and IPv6 only because dockerd happened to enable it.

***

## Address plan

IPv6 inside the VPN uses the ULA prefix **`fd33:5692:1834::/48`** (randomly generated, RFC 4193).

### Tunnels

| Tunnel | Port  | MTU  | Link                 | First address                              | Second address                              |
|--------|-------|------|----------------------|--------------------------------------------|---------------------------------------------|
| wg0    | 51820 | 1388 | ruby clients         | ruby `192.168.204.254/24`, `fd33:5692:1834:204::254/64` | per client, below                |
| wg1    | 51821 | 1388 | ruby – home     | ruby `172.31.1.1/30`, `fd33:5692:1834:ff01::1/64`   | home `172.31.1.2`, `…:ff01::2`  |
| wg2    | 51822 | 1420 | ruby – jennie        | ruby `172.31.1.5/30`, `fd33:5692:1834:ff02::1/64`   | jennie `172.31.1.6`, `…:ff02::2`     |
| wg3    | 51823 | 1388 | jennie – home   | jennie `172.31.1.9/30`, `fd33:5692:1834:ff03::1/64` | home `172.31.1.10`, `…:ff03::2` |
| wg0    | 51820 | 1388 | jennie clients  | jennie `192.168.205.254/24`, `fd33:5692:1834:205::254/64` | per client, below |

`172.31.1.0/24` is for site-to-site transit links, one `/30` each, paired with `fd33:5692:1834:ffNN::/64`. ruby takes the first address on its links. On links without ruby, the server takes the first address and the router the second. The next free link is `172.31.1.12/30`, `ff04::/64`, port 51824.

The home tunnels use MTU 1388 to allow for the home connection (e.g. PPPoE). wg2 runs between two hosts on clean IPv6, so it uses 1420 (1500 minus 80 bytes of WireGuard-over-IPv6 overhead). A don't-fragment ping of MTU − 28 (IPv4) or MTU − 48 (IPv6) bytes checks a link: `ping -M do -s 1360 172.31.1.10` for wg3. If that fails but smaller sizes work, the home link's MTU is lower; lower it on both ends of wg1 and wg3.

### Clients (wg0)

| Client      | IPv4             | IPv6                      | IPv4 on jennie   | IPv6 on jennie            |
|-------------|------------------|---------------------------|------------------|---------------------------|
| mba         | `192.168.204.1`  | `fd33:5692:1834:204::1`   | `192.168.205.1`  | `fd33:5692:1834:205::1`   |
| iphone-peet | `192.168.204.2`  | `fd33:5692:1834:204::2`   | `192.168.205.2`  | `fd33:5692:1834:205::2`   |
| mbp         | `192.168.204.4`  | `fd33:5692:1834:204::4`   | `192.168.205.4`  | `fd33:5692:1834:205::4`   |

On jennie each client keeps its host number and reuses its key pair, with a PSK of its own.

`.3` belonged to sylvie (retired) and `.5` to home (moved to wg1). Don't reuse them until the old peers are gone everywhere.

### Networks behind each site

| Site      | IPv4                                                 | IPv6                                                              |
|-----------|------------------------------------------------------|-------------------------------------------------------------------|
| ruby      | `192.168.254.254/32`, `192.168.254.253/32` (dummy0/dummy1) | `fd33:5692:1834:254::254/128`, `fd33:5692:1834:254::253/128` (dummy0/dummy1)                |
| jennie    | `192.168.254.2/32` (dummy0)                          | `fd33:5692:1834:254::2/128` (dummy0)                              |
| home | `192.168.8.0/21`                                     | `fd33:5692:1834:1000::/56` (one `/64` per LAN: lan `1000::/64`, iot `1001::/64`, guest `1002::/64`), plus the ISP's own ranges |

`fd33:5692:1834:254::/64` holds all the sites' service addresses, with host numbers matching their IPv4 ones. ruby's dummies used to be `fd00::1`/`fd00::2`, but `fd00::/64` is a common default on other networks (Fritz!Box routers use it on the LAN), so a client or home network using it would collide. rspamd's `local_addrs` (`fd00::/8`) covers both old and new.

### Home LANs and the ISP's IPv6

The home LANs keep the IPv6 ranges the ISP gives them. **Do not translate (NPTv6/NAT66) them on the router.** Instead, the router also advertises a ULA `/64` from `fd33:5692:1834:1000::/56` on each LAN. Hosts then have both addresses, and the standard source-address rules (RFC 6724) pick:

- the **ULA** address when talking to `fd33:…` destinations across the VPN
- the **ISP** address when talking to the internet

So nothing needs translating, and an ISP renumbering doesn't affect the VPN. One side effect: for a name that resolves to both IPv4 and a ULA address, hosts prefer IPv4. That's harmless.

**On the router,** the global ULA prefix is `fd33:5692:1834::/48` (replacing GL's default `fd0c:aa7b:aee6::/48`). The LANs get their `/64`s by static `ip6addr` on the interface, and the ISP `/60` delegations are unchanged. odhcpd first gave iot an extra ULA `fd33:5692:1834::/60`, because iot had `ip6assign` and no `ip6class`. Setting iot's `ip6class` to LAN's list stopped that, and the stray address and route were removed. Clients only need the `/64` per LAN; a `/60` isn't a client prefix.

**Exception: IPv6 internet traffic sent via jennie.** For internet destinations, hosts use their ISP address as the source. jennie only accepts and routes back VPN addresses, so the router masquerades IPv6 going into wg3 to its wg3 address `fd33:5692:1834:ff03::2`, and jennie then NAT66s that to its own address. The rule skips VPN sources (`! -s fd33:5692:1834::/48`), so only ISP-sourced traffic is translated and jennie still sees home hosts' real ULA addresses. Tunnel-to-tunnel traffic is never translated. IPv4 needs no NAT on the router.

### Internet exits

| Exit   | IPv4 | IPv6 | Used by |
|--------|------|------|---------|
| ruby   | snat to `46.105.253.72` | **none**, no NAT66 on ruby | clients' IPv4, by default |
| jennie | snat to `57.129.180.73` | snat to `2001:41d0:801:2000::180f` (NAT66; jennie has a single `/128`) | clients' IPv6, opted-in clients' IPv4, home traffic the router sends to it, and all of jennie's own clients' traffic |

**On ruby:**

- **wg2 accepts any destination.** The jennie peer's allowed IPs are `0.0.0.0/0, ::/0`, so ruby can hand any destination to jennie. The main routing table still only routes jennie's own addresses into wg2.
- **Table 200 ("via jennie")** has a default route into wg2 for both families.
- **Routing-policy rules** decide what uses table 200:
  - priority 900: destinations in `fd33:5692:1834::/48`, `192.168.0.0/16` and `172.16.0.0/12` always use the main table, so clients sent via jennie still reach ruby, each other, home and jennie
  - priority 1000: client IPv6 (`fd33:5692:1834:204::/64`) goes to table 200, so it exits via jennie
  - client IPv4 is commented out by default; a `from: 192.168.204.N/32` rule per client switches that client's IPv4 exit to jennie (see [Day-to-day](#day-to-day))
- **ruby's firewall still drops IPv6 from any tunnel heading out of ens3.** If the policy routing were ever missing, client IPv6 fails closed instead of leaking ULA-sourced packets.

**On jennie:**

- jennie's firewall, `jennie/nftables.conf`, does NAT44 and NAT66 out of ens3 and clamps TCP MSS. Its forward chain has a drop policy and only allows VPN → internet and the replies back (see [Firewall on jennie](#firewall-on-jennie)).
- Return traffic needs nothing extra: jennie already routes the client and home ranges back over wg2 and wg3.

**On home:** wg3's peer allows `0.0.0.0/0, ::/0`, and that's intentional. The router's GL route policy decides what goes into wg3, not the WireGuard config. The main routing table only holds routes to jennie's own addresses (`172.31.1.9`, `192.168.254.2`, `fd33:5692:1834:ff03::1`, `fd33:5692:1834:254::2`). Table 1002 has a default route via wg3, but only traffic the policy marks (`0x2000`) uses it, so home traffic isn't sent to jennie by default.

Today the policy is the `UK` rule (tunnel 6611). Its targets are in `/etc/domain_mac_list/dst_net6611_manual`: 28 BBC domains, resolved by the router's dnsmasq, plus jennie's `192.168.254.2` and `fd33:5692:1834:254::2`. **Domain-based policy only sees DNS that goes through the router.** A device using its own DNS (browser DNS-over-HTTPS, iCloud Private Relay, a hard-coded resolver) gets BBC addresses dnsmasq never sees, so that traffic isn't marked and leaves via the ISP. If BBC checks fail on one device, check its DNS first.

***

## Home router

The router's settings live in `uci`, written by the GL.iNet UI; `home/wg1.conf` and `home/wg3.conf` are wg-quick-format references, not something to install. `router/README.md` covers the router as a whole, including the policy rules at priority 19000 that make router-originated traffic to the tunnels' far ends work.

| Setting | wg1 (`wgclient1`, to ruby) | wg3 (`wgclient2`, to jennie) |
|---------|----------------------------|------------------------------|
| Tunnel address | `172.31.1.2/30`, `fd33:5692:1834:ff01::2/64` | `172.31.1.10/30`, `fd33:5692:1834:ff03::2/64` |
| MTU | `1388` | `1388` |
| Endpoint | `[2001:41d0:305:2100::1:3a0e]:51821` | `[2001:41d0:801:2000::180f]:51823` |
| Persistent keepalive | `25` | `25` |
| Peer allowed IPs | `172.31.1.1/32, fd33:5692:1834:ff01::1/128, 192.168.204.0/24, fd33:5692:1834:204::/64, 192.168.254.253/32, 192.168.254.254/32, fd33:5692:1834:254::254/128, fd33:5692:1834:254::253/128` | `0.0.0.0/0, ::/0` (jennie is an internet exit) |
| Routing table | 1001 | 1002, holding the default via wg3; automatic routes off (wg-quick `Table = off`), so main is unaffected |
| Routes | `route6` entries for the remote IPv6 prefixes, which land in table 1001 (the interface's `ip6table` wins over a per-route `table`); IPv4 uses the table's default | in main: `172.31.1.9/32`, `192.168.254.2/32`, `fd33:5692:1834:ff03::1/128`, `fd33:5692:1834:254::2/128`, as `route`/`route6` entries on `wgclient2` |
| Policy | site-to-site IP set `dst_net4399` | GL route policy `UK` (tunnel 6611, mark `0x2000`) |
| NAT | none | IPv6 MASQUERADE for non-VPN sources, in `/etc/firewall.user` |

The router's firewall accepts wgclient1/wgclient2 → lan.

***

## Firewall on ruby

ruby's firewall is the hand-written `/etc/nftables.conf` (`table inet filter`, plus `table ip wgnat` for client NAT), and `ruby/nftables.conf` matches it. Docker manages its own `ip`/`ip6` tables through iptables-nft. There's no provider firewall (no OVH network firewall or security groups) on either server, so each host's nftables is the only filtering.

What the WireGuard work changed against the original (`ruby/nftables.conf.orig`, diff in `ruby/nftables.conf.diff`):

| Area | Change |
|------|--------|
| `define`s | `WGIFS = { "wg0", "wg1", "wg2" }`, `DOCKERNET6`, `JENNIE6` |
| input | UDP 51821 accepted on `$PUB6` from anywhere (home has a dynamic address); UDP 51822 on `$PUB6` only from jennie |
| input | The VPN-side service rules (SSH, DNS, web, mail submission/IMAP/Sieve, mosh) apply to all `$WGIFS`, not just wg0. The firewall lets home LANs and jennie through, and the services themselves decide who they accept (see [Service allow lists](#service-allow-lists)) |
| input | Removed: the dead `wg0` rule for TCP 19080 (see the end of this README) |
| forward | `wg0 ↔ wg0` accept became `$WGIFS ↔ $WGIFS`: anything in the VPN reaches anything else |
| forward | The "no route into Docker or other private space" drops apply to all tunnels, with an IPv6 rule for Docker's `fda6:50ae:40f0::/64` |
| forward | New: `ens3 → $WGIFS` drop. Under the accept policy, nothing previously stopped the internet side from starting connections into the VPN |
| forward | New: IPv6 from any tunnel to ens3 is dropped (no NAT66 on ruby) |
| nat | IPv4 `wgnat` only, deliberately no NAT66 |

### Service allow lists

DNS, mail submission and ManageSieve on ruby are open to **everything on the VPN**: clients, the home LANs, jennie and the tunnel links, over IPv4 and IPv6. They're reached at the wg0 addresses (`192.168.204.254`, `fd33:5692:1834:204::254`), which every site routes to ruby.

| Service | Listens on | What else gates it |
|---------|------------|--------------------|
| BIND | `192.168.204.0/24` and `fd33:5692:1834:204::/64` (the wg0 addresses), plus loopback and Docker | the `wireguard` view's `match-clients` and ACLs, all `acl "vpn"` |
| Postfix submission/smtps | `192.168.204.254`, `[fd33:5692:1834:204::254]` | SMTP AUTH from every source; the VPN is deliberately absent from `mynetworks` |
| Dovecot ManageSieve | `192.168.204.254`, `192.168.254.254` and their IPv6 twins | TLS and auth from every source |
| Dovecot IMAPS | `*, ::` | auth |
| nftables | n/a | the `$WGIFS` input rules |

Postfix's `wireguard_clients.cidr` exists but isn't referenced: binding only the wg0 addresses plus SASL is the real gate, and `main.cf`'s comments say so.

`acl "vpn"` in `named.conf.local`:

| Range | What |
|-------|------|
| `192.168.204.0/24` | wg0 clients |
| `192.168.205.0/24` | jennie's wg0 clients (see [Clients on jennie](#clients-on-jennie)) |
| `192.168.8.0/21` | home LANs |
| `192.168.254.0/24` | site service addresses (dummies) |
| `172.31.1.0/24` | tunnel links: jennie's and the home router's own queries leave from their tunnel address |
| `fd33:5692:1834::/48` | the whole VPN ULA prefix |

The `wireguard` view also resolves the lab's internal names. `home` and `8.168.192.in-addr.arpa` are `static-stub` zones pointing at Pythia (`192.168.8.52`), the lab's authoritative server, reached over wg1. They don't go to Themis or Delphi because those only accept queries from the home LAN and the Proxmox lab networks. `disable-empty-zone "168.192.in-addr.arpa"` stops BIND's built-in RFC 1918 empty zone answering the lab's PTRs first, which is also why every other `192.168.x` range the VPN uses needs a reverse zone of its own (see [Reverse zones](#reverse-zones)). No DNSSEC exception is needed because ruby doesn't validate (`dnssec-validation no`).

Home hosts reach ruby over IPv6 from their **ULA** address (see [Home LANs and the ISP's IPv6](#home-lans-and-the-isps-ipv6)). Their ISP address isn't in wg1's allowed IPs, so it never gets through. That's by design.

**Start order:** Postfix and Dovecot bind specific addresses, which must exist when they start, so both wait for systemd-networkd to finish configuring them (`ruby/services/etc/systemd/`):

- **Dovecot** waits for `systemd-networkd-wait-online@wg0:routable` and `@dummy0:routable`.
- **Postfix** waits for wg0 the same way. Before, it was only ordered after `network.target`, which waits for no interface, so it could fail to bind `192.168.204.254` at boot.

### Docker's IPv6 forward policy is DROP

Docker runs with `"ip6tables": true`, so its `ip6 filter` FORWARD chain has **policy drop**. As the header of `nftables.conf` explains, a drop in any chain on the forward hook wins, so accepts in `nftables.conf` can't override it. Without an exception, all IPv6 forwarding through ruby is dropped.

`ruby/wg-docker-user.service` adds narrow accepts to Docker's `DOCKER-USER` chain:

- **IPv6:** tunnel ↔ tunnel only. With no NAT66, IPv6 never goes from a tunnel to the internet.
- **IPv4:** tunnel ↔ tunnel, tunnel → ens3, and ens3 → tunnel for established/related traffic. IPv4's policy is currently accept, so these are insurance.

It runs after dockerd, re-runs whenever Docker restarts (`PartOf=docker.service`), and checks before inserting, so rules never duplicate. Nothing in it touches traffic to containers, so Docker's isolation still applies.

### Applying firewall changes

Use **`systemctl reload nftables`**, never `restart`. The unit's `ExecStop` is `nft flush ruleset`, which wipes Docker's tables as well, and container networking stays broken until dockerd restarts. `reload` re-runs the file, whose declare-then-delete idiom only replaces ruby's own tables. The same goes for jennie, for consistency.

***

## Firewall on jennie

jennie had no firewall. `jennie/nftables.conf` follows ruby's conventions (inet tables, declare-then-delete, no `flush ruleset`) rather than using UFW. UFW's default forward policy is drop, and NAT, especially NAT66, can only be added by hand-editing its `before.rules`/`before6.rules`. For a NAT exit it ends up being nftables underneath anyway, split across two syntaxes.

| Chain | Policy | Rules |
|-------|--------|-------|
| input | drop | loopback; established/related; ICMP and the ICMPv6 essentials; DHCPv4/DHCPv6 replies from OVH; SSH; UDP 51822 from ruby's IPv6 only; UDP 51823 from anywhere (home is dynamic); UDP 51820 (wg0, clients) from anywhere on both families; everything from wg2/wg3; a placeholder for public services |
| forward | drop | MSS clamping; wg ↔ wg; wg → ens3; ens3 → wg for established/related only |
| output | accept | none |
| nat (`inet wgnat`) | n/a | snat VPN IPv4 sources to `57.129.180.73` and VPN IPv6 (`fd33:5692:1834::/48`) to `2001:41d0:801:2000::180f`, on ens3 only |

The forward chain can use a drop policy here, unlike on ruby, because jennie has no Docker. If Docker is ever installed, its IPv6 FORWARD policy is drop as on ruby, and jennie would need a copy of `wg-docker-user.service`, also allowing IPv6 `wg+ → ens3`. Anything else jennie serves publicly needs a rule under "Public services".

***

## Clients

### Clients on ruby

Each client's ruby tunnel:

```ini
[Interface]
Address = 192.168.204.1/32, fd33:5692:1834:204::1/128     # mba; iphone-peet .2 / ::2, mbp .4 / ::4

[Peer]
AllowedIPs = 0.0.0.0/0, ::/0                              # full tunnel
```

Full tunnel sends IPv4 to the internet via ruby (or jennie, if opted in on ruby) and IPv6 via jennie. Which exit a client uses isn't set on the client: ruby's routing-policy rules decide it (see [Internet exits](#internet-exits)). For a split tunnel, use only the networks ruby routes; clients don't need the `172.31.1.0/24` transit addresses:

```ini
AllowedIPs = 192.168.204.0/24, 192.168.8.0/21, 192.168.254.2/32, 192.168.254.253/32, 192.168.254.254/32, fd33:5692:1834:204::/64, fd33:5692:1834:1000::/56, fd33:5692:1834:254::2/128, fd33:5692:1834:254::254/128, fd33:5692:1834:254::253/128
```

### Clients on jennie

mba, mbp and iphone-peet each have a second tunnel, to jennie's `wg0` on the standard port 51820, so they can still reach home, ruby and the internet when ruby is down. The two tunnels are alternatives: a device runs one or the other, and the WireGuard apps only bring up one at a time anyway.

- **Keys:** each device reuses the key pair it has on ruby. WireGuard allows one key to have peers on several servers. Each peer gets a fresh PSK on jennie.
- **Addresses:** `192.168.205.0/24` and `fd33:5692:1834:205::/64`, with the same host number as on ruby.
- **Endpoint:** jennie's public IPv4 *and* IPv6. Unlike the site-to-site tunnels, wg0 listens on both, since mobile networks are often IPv4-only.
- **Reach:** home over wg3 and ruby over wg2, both direct from jennie. The other ends route back to `192.168.205.0/24` and `fd33:5692:1834:205::/64`: on ruby with main-table routes in `82-wireguard-wg2.yaml`, on the router with two policy rules at priority 19000 into table 1002, like the other `s2s_*` rules (`router/README.md`).
- **Internet:** exits via jennie with NAT44 and NAT66, both families, for every client. Nothing needs opting in.

### Client config

The jennie tunnel, next to the existing one:

```ini
[Interface]
PrivateKey = <the device's existing private key, from its ruby tunnel>
Address    = 192.168.205.1/32, fd33:5692:1834:205::1/128     # mba; iphone-peet .2 / ::2, mbp .4 / ::4
DNS        = 192.168.205.254, fd33:5692:1834:205::254

[Peer]
PublicKey    = <jennie wg0 public key>
PresharedKey = <psk jennie-mba>
Endpoint     = 57.129.180.73:51820
AllowedIPs   = 0.0.0.0/0, ::/0
```

The IPv4 endpoint works on IPv6-only networks too, through the NAT64 that iOS and macOS synthesise. For a split tunnel, use the networks jennie routes in place of `0.0.0.0/0, ::/0`:

```ini
AllowedIPs = 192.168.205.0/24, 192.168.204.0/24, 192.168.8.0/21, 192.168.254.2/32, 192.168.254.253/32, 192.168.254.254/32, fd33:5692:1834:205::/64, fd33:5692:1834:204::/64, fd33:5692:1834:1000::/56, fd33:5692:1834:254::2/128, fd33:5692:1834:254::254/128, fd33:5692:1834:254::253/128
```

***

## DNS

### DNS on jennie

jennie runs its own BIND (`jennie/services/etc/bind/`), so jennie's clients don't depend on ruby for names. It gives the same answers as ruby's `wireguard` view:

- **Split-horizon and reverse zones:** the same files as ruby's `/etc/bind/wireguard/` (see [Reverse zones](#reverse-zones)). The split-horizon answers still point at ruby (`192.168.204.254`), so mail follows ruby's availability, but resolving names doesn't.
- **`home.` and the lab's reverse zone:** `static-stub` to Pythia over wg3, as on ruby.
- **No views.** jennie has no Docker clients to tell apart from the VPN, so Debian's own `named.conf` and default zones stay. The same `acl "vpn"` as ruby's, plus jennie's clients, gates every query.
- **Validating**, unlike ruby, which turns validation off for Postfix's DANE. `home.` and `8.168.192.in-addr.arpa` are unsigned, so they're listed in `validate-except`.
- **Listens on** `192.168.205.254`, `fd33:5692:1834:205::254`, jennie's dummy0 addresses and loopback, never ens3.

jennie's own lookups of lab names don't go through its BIND. wg3's `nameservers` block in `83-wireguard-wg3.yaml` sends `home.` and `8.168.192.in-addr.arpa` to Pythia as routing-only domains, so systemd-resolved queries Pythia over wg3 for those names and nothing else. Themis and Delphi would refuse jennie's queries. If wg3 is down, `.home` stops resolving on jennie, but the lab is unreachable then anyway.

### Split horizon

The `wireguard` view's `mail.peetvandesande.com` answers `192.168.204.254` and `fd33:5692:1834:204::254`, so VPN clients reach mail over either family, preferring IPv6. That's separate from the home LAN's override in `dns/` (A only, to `192.168.254.254`), which is A only for reasons of its own.

### Reverse zones

| Zone | Range |
|------|-------|
| `204.168.192.in-addr.arpa` | ruby's clients |
| `205.168.192.in-addr.arpa` | jennie's clients |
| `254.168.192.in-addr.arpa` | the sites' service addresses |
| `1.31.172.in-addr.arpa` | the transit links, named `<site>-<tunnel>` |
| `4.3.8.1.2.9.6.5.3.3.d.f.ip6.arpa` | the whole ULA `/48`, with the same names as the IPv4 zones |

All five are served on both servers from the same files: one copy in the repo, in `jennie/services/etc/bind/wireguard/`, installed on ruby too. Change them on both hosts together. They're copies rather than a primary and a secondary on purpose: the repo is already the single source, a secondary would add a TSIG key and a zone that expires when its primary is down, and the zones only change when a device or site is added.

The 192.168.x zones matter most. Both servers disable the `168.192.in-addr.arpa` empty zone so the lab's PTRs reach Pythia, so without a zone of their own those lookups go out to the public AS112 servers and fail. The transit and ULA zones sit beneath BIND's automatic `31.172.in-addr.arpa` and `d.f.ip6.arpa` empty zones, which already answer NXDOMAIN at once; they add names. The home LANs' SLAAC addresses (`1000::/56`) have no PTRs and get that fast NXDOMAIN.

On ruby they're also in the `internal` view, where the host's own daemons resolve, so Postfix and Dovecot log VPN peers by name. Only the reverse zones: the split-horizon forward zones stay out of `internal` on purpose (see `named.conf.local`).

***

## Files in this directory

Every private key and PSK in these files is a `<placeholder>`. The real keys, PSKs, filled configs and the old wg-quick configs live outside git, in `~/projects/homelab-private/wireguard/`.

| File | Installed on | Destination | Purpose |
|------|--------------|-------------|---------|
| `ruby/70-dummy-interfaces.yaml` | ruby | `/etc/netplan/` | dummy0/dummy1, ruby's service addresses |
| `ruby/80-wireguard-wg0.yaml` | ruby | `/etc/netplan/` | wg0, clients |
| `ruby/81-wireguard-wg1.yaml` | ruby | `/etc/netplan/` | wg1, to home |
| `ruby/82-wireguard-wg2.yaml` | ruby | `/etc/netplan/` | wg2, to jennie, with table 200 and the exit policy rules |
| `ruby/nftables.conf` | ruby | `/etc/nftables.conf` | ruby's firewall |
| `ruby/networkd-forwarding.conf` | ruby | `/etc/systemd/networkd.conf.d/forwarding.conf` | IPv4/IPv6 forwarding, owned by networkd |
| `ruby/wg-docker-user.service` | ruby | `/etc/systemd/system/` | IPv4/IPv6 `DOCKER-USER` accepts for WireGuard forwarding |
| `ruby/services/etc/…` | ruby | same path under `/etc` | BIND, Postfix and Dovecot configs with IPv6 listeners, plus systemd start-order drop-ins |
| `ruby/nftables.conf.orig`, `ruby/nftables.conf.diff`, `ruby/current-nft-ruleset` | none | none | ruby's firewall before the WireGuard work (2026-10-08), the diff against it, and the live ruleset then |
| `ruby/services/orig/etc/…`, `ruby/services/services.diff` | none | none | The service configs before the WireGuard work (2026-10-09), and the diff against them |
| `jennie/70-dummy0.yaml` | jennie | `/etc/netplan/` | dummy0 with `192.168.254.2`, `fd33:5692:1834:254::2` |
| `jennie/80-wireguard-wg0.yaml` | jennie | `/etc/netplan/` | wg0, clients |
| `jennie/82-wireguard-wg2.yaml` | jennie | `/etc/netplan/` | wg2, to ruby |
| `jennie/83-wireguard-wg3.yaml` | jennie | `/etc/netplan/` | wg3, to home, with the routing-only DNS domains for `home.` |
| `jennie/networkd-forwarding.conf` | jennie | `/etc/systemd/networkd.conf.d/forwarding.conf` | IPv4/IPv6 forwarding (internet exit), owned by networkd |
| `jennie/nftables.conf` | jennie | `/etc/nftables.conf` | jennie's whole firewall, including the exit's forwarding rules and NAT44/NAT66 |
| `jennie/services/etc/bind/…` | jennie (zone files: ruby too) | same path under `/etc` | jennie's BIND; the zone files under `wireguard/` are the shared split-horizon and reverse zones |
| `home/wg1.conf`, `home/wg3.conf` | none | none | The router's wg1 and wg3 settings in wg-quick format, as a reference |
| `fill-secrets.py` | none | none | Fills key/PSK placeholders from a wg-quick config on stdin; refuses to run inside a git work tree |

The ruby files are split one per tunnel, so each can be installed and removed on its own.

***

## Day-to-day

```bash
sudo wg show                               # all tunnels: handshakes, endpoints, transfer
networkctl status wg1                      # networkd's view, including routes and errors
sudo netplan status                        # netplan's view of all interfaces
journalctl -u systemd-networkd -b          # networkd errors (bad keys, route conflicts)
```

**Changing an existing tunnel** (new peer, changed allowed IPs, new key): networkd doesn't reliably apply changes to a WireGuard interface that already exists. Two ways:

- **Without dropping anyone:** edit the YAML, run `sudo netplan generate` so it persists, and apply the same change live with `wg set`, e.g.
  ```bash
  sudo wg set wg0 peer <pubkey> preshared-key <(echo <psk>) allowed-ips 192.168.204.6/32,fd33:5692:1834:204::6/128
  ```
  Add a route with `ip route add` too if the change brings in a new network.
- **Simple, but drops that tunnel for a moment:** edit the YAML, then
  ```bash
  sudo netplan generate && sudo ip link del wgN && sudo networkctl reload
  ```

**Sending a client's IPv4 via jennie:** in `ruby/82-wireguard-wg2.yaml`, add `- { from: "192.168.204.N/32", table: 200, priority: 1000 }` under `routing-policy`. Then `netplan generate` and either `sudo ip rule add from 192.168.204.N/32 table 200 priority 1000` (live, no interruption) or recreate wg2. Remove the rule to switch back.

**Adding a client:** generate a key on the device, take the next free address (`192.168.204.6` / `fd33:5692:1834:204::6`), and add a peer to `80-wireguard-wg0.yaml` with a fresh PSK (`wg genpsk`). For a fallback tunnel too, add the same public key to `jennie/80-wireguard-wg0.yaml` with the same host number in `192.168.205.0/24` and a PSK of its own. Add its PTRs to the shared reverse zones: IPv4 in `204`/`205`, IPv6 in `4.3.8.1.2.9.6.5.3.3.d.f.ip6.arpa`.

**Adding a site:**

1. Use the next transit link (`172.31.1.12/30`, `fd33:5692:1834:ff04::/64`, port 51824), and add PTRs for both ends to `1.31.172.in-addr.arpa` and the ULA zone.
2. Create a YAML file on each server end, with `routes:` for the site's networks.
3. Add the site's networks to the allowed IPs and routes of every tunnel that should reach it, and to the clients' split-tunnel lists.
4. If the tunnel ends on ruby: add the interface to `WGIFS` in `/etc/nftables.conf`, add an input rule for its UDP port on `$PUB6`, and `systemctl reload nftables`. `wg-docker-user.service` matches `wg+`, so it needs no change.

***

## Found while reviewing ruby's firewall (not WireGuard)

**Port 19080 was reachable from the internet. Fixed on 2026-10-08.** The `wordpress-sogode-nginx-1` container was published on `0.0.0.0:19080` and `[::]:19080`. Docker DNATs published ports in `prerouting`, so the traffic never hit the `input` chain, and `inet filter forward` has an accept policy. The live ruleset's counters showed connections from outside reaching the container. `nftables.conf`'s `wg0` input rule for 19080 was dead for the same reason, and is gone.

It's meant to be fronted by the host's nginx (`proxy_pass http://localhost:19080` in `/etc/nginx/sites-available/sogode.com`). `/opt/wordpress-sogode/docker-compose.yml` publishes it on loopback only:

```yaml
    ports:
      - 127.0.0.1:${WEB_PORT:-80}:80
      - "[::1]:${WEB_PORT:-80}:80"
```

Both loopbacks are needed because `localhost` resolves to `::1` as well as `127.0.0.1`. Port 19080 listens on loopback only, `https://sogode.com/` through the host nginx returns 200, and `http://145.239.73.18:19080/` gets no response.

`/etc/nginx/sites-available/sogode.com.wordpress` (not enabled) proxies to the container's bridge address (`wordpress-sogode-nginx-1.docker.local:19080`). That wouldn't work, since the container listens on port 80 inside the bridge. It's harmless while it isn't enabled.
