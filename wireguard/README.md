# WireGuard: ruby, jennie and home

The WireGuard design for **ruby**, **jennie** and the **home** router: what goes where, and the steps to deploy it.

**To deploy, work through [TASKS.md](TASKS.md):** every remaining step in order, with commands. This README is the reference behind it.

Status as of 2026-10-16: the configs in this directory are **written and validated** (`netplan generate` succeeds for both ruby's and jennie's file sets). **Deployed**: the whole rollout is live and cleaned up (TASKS.md phases 0–7). Only the clients on jennie (phase 8) are still to do.

Done so far:

- `/etc/wireguard.bak-2026-10-08` backup made on ruby
- ruby's wg1 and wg2 keys generated (`wg1.key`/`wg1.pub`, `wg2.key`/`wg2.pub`)
- PSKs generated for ruby–jennie (`jennie.psk`) and home–jennie (`home-jennie.psk`)
- jennie's wg2 key generated on jennie (public key `+0MxQ46pU2YUBHPrY7cLHr+ahAhS5fMXImlLRvBoOgk=`)
- Task 1a: ruby's wg0 key and the client/home PSKs filled in
- Task 2b/2c: ruby's new `/etc/nftables.conf` installed (2026-10-08 20:44) and `wg-docker-user.service` enabled. `ruby/nftables.conf.orig` is the pre-change original.
- ruby: `82-wireguard-wg2.yaml` installed (2026-10-08 20:57); wg2 is up with the via-jennie table and rules
- jennie: wg2 and dummy0 are up. From ruby, `172.31.1.6`, `fd33:5692:1834:ff02::2`, `192.168.254.2` and `fd33:5692:1834:254::2` all answer (checked 2026-10-09).
- jennie: wg3 is up
- Task 2a: forwarding owned by networkd on ruby
- Task 2d: jennie's firewall and forwarding, so the exit via jennie works
- Task 2e: ruby's dummies renumbered to `fd33:5692:1834:254::254`/`::253`
- ruby's live `/etc/nftables.conf` matches `ruby/nftables.conf`, comments included
- `.home` names for jennie itself: routing-only domains to Pythia on wg3 (TASKS.md 3.5)
- no provider firewall is in use on either server (Task 2f)
- Task 5: ruby's wg0 on netplan, home moved to wg1 (`wgclient1`), and 5e's service changes (IPv6 listeners, VPN-wide DNS, start order), including ruby's `home.` zones
- Task 6: clients updated, with their IPv4 exits chosen
- Task 7: tested end to end, ruby and jennie rebooted
- Task 8: secrets and the wg-quick leftovers removed
- home router: wg3 is configured and up, with the routes, IPv6 masquerade and destination policy described in [Task 4c](#task-4-jennie--home-wg3), and the LAN ULA `/64`s (see [Home LANs and the ISP's IPv6](#home-lans-and-the-isps-ipv6))

Written 2026-10-15, not yet deployed:

- **Clients on jennie:** a second `wg0` on jennie for the same three devices, with jennie's own BIND, routes back on ruby and two policy rules on the router (see [Clients on jennie](#clients-on-jennie), TASKS.md phase 8)

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
| home | wg1, wg3            |

### Netplan, not wg-quick

ruby and jennie configure their networks with netplan, so all WireGuard interfaces (including ruby's existing wg0) are netplan `tunnels:` of `mode: wireguard`, rendered by systemd-networkd. Things that differ from wg-quick:

- **Routes are explicit.** networkd doesn't add routes for `AllowedIPs`, so each YAML file lists the routes for the far end's networks under `routes:`. The transit `/30` and `/64` come from the interface addresses.
- **No PostUp/PostDown hooks.** ruby's firewall and NAT stay where they already are, in `/etc/nftables.conf` (see [Firewall on ruby](#firewall-on-ruby)). The one thing that can't go there, an exception in Docker's IPv6 forward chain, is a small systemd unit, `wg-docker-user.service`.
- **Keys are inline in the YAML.** Files in `/etc/netplan` must be mode `600`; networkd's generated copies in `/run/systemd/network` are `640 root:systemd-network`.
- **Changes to an existing tunnel** don't always get applied by `networkctl reload`. See [Day-to-day](#day-to-day).

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

The home tunnels use MTU 1388 to allow for the home connection (e.g. PPPoE). wg2 runs between two hosts on clean IPv6, so it uses 1420 (1500 minus 80 bytes of WireGuard-over-IPv6 overhead).

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

ruby's dummies used to be `fd00::1`/`fd00::2`. `fd00::/64` is a common default on other networks (Fritz!Box routers use it on the LAN), so a client or home network using it would collide. They're being renumbered into `fd33:5692:1834:254::/64` (Task 2e), with `::254`/`::253` matching their IPv4 addresses. `fd33:5692:1834:254::/64` holds all the sites' service addresses.

### Home LANs and the ISP's IPv6

The home LANs keep the IPv6 ranges the ISP gives them. **Do not translate (NPTv6/NAT66) them on the router.** Instead, the router also advertises a ULA `/64` from `fd33:5692:1834:1000::/56` on each LAN. Hosts then have both addresses, and the standard source-address rules (RFC 6724) pick:

- the **ULA** address when talking to `fd33:…` destinations across the VPN
- the **ISP** address when talking to the internet

So nothing needs translating, and an ISP renumbering doesn't affect the VPN. One side effect: for a name that resolves to both IPv4 and a ULA address, hosts prefer IPv4. That's harmless.

**On the router,** the global ULA prefix is `fd33:5692:1834::/48` (replacing GL's default `fd0c:aa7b:aee6::/48`). The LANs get their `/64`s by static `ip6addr` on the interface, and the ISP `/60` delegations are unchanged. odhcpd first gave iot an extra ULA `fd33:5692:1834::/60`, because iot had `ip6assign` and no `ip6class`. Setting iot's `ip6class` to LAN's list stopped that, and the stray address and route were removed. Clients only need the `/64` per LAN; a `/60` isn't a client prefix.

**Exception: IPv6 internet traffic sent via jennie.** For internet destinations, hosts use their ISP address as the source. jennie only accepts and routes back VPN addresses, so the router must masquerade IPv6 going into wg3 to its wg3 address `fd33:5692:1834:ff03::2`. jennie then NAT66s that to its own address. This only applies to the traffic the router chooses to send via jennie; tunnel-to-tunnel traffic is still never translated. IPv4 needs no NAT on the router.

### Internet exits

| Exit   | IPv4 | IPv6 | Used by |
|--------|------|------|---------|
| ruby   | snat to `46.105.253.72` (unchanged) | **none**, no NAT66 on ruby | clients' IPv4, by default |
| jennie | snat to `57.129.180.73` | snat to `2001:41d0:801:2000::180f` (NAT66; jennie has a single `/128`) | clients' IPv6, opted-in clients' IPv4, home traffic the router sends to it, and all of jennie's own clients' traffic |

**On ruby:**

- **wg2 accepts any destination.** The jennie peer's allowed IPs are `0.0.0.0/0, ::/0`, so ruby can hand any destination to jennie. The main routing table still only routes jennie's own addresses into wg2.
- **Table 200 ("via jennie")** has a default route into wg2 for both families.
- **Routing-policy rules** decide what uses table 200:
  - priority 900: destinations in `fd33:5692:1834::/48`, `192.168.0.0/16` and `172.16.0.0/12` always use the main table, so clients sent via jennie still reach ruby, each other, home and jennie
  - priority 1000: client IPv6 (`fd33:5692:1834:204::/64`) goes to table 200, so it exits via jennie
  - client IPv4 is commented out by default; add a `from: 192.168.204.N/32` rule per client to switch that client's IPv4 exit to jennie
- **ruby's firewall still drops IPv6 from any tunnel heading out of ens3.** If the policy routing were ever missing, client IPv6 fails closed instead of leaking ULA-sourced packets.

**On jennie:**

- Forwarding is on for both families, set globally in systemd-networkd (`jennie/networkd-forwarding.conf`).
- jennie's firewall, `jennie/nftables.conf`, does NAT44 and NAT66 out of ens3 and clamps TCP MSS. Its forward chain has a drop policy and only allows VPN → internet and the replies back (see [Firewall on jennie](#firewall-on-jennie)).
- Return traffic needs nothing extra: jennie already routes the client and home ranges back over wg2 and wg3.

**On home:** wg3's peer allows `0.0.0.0/0, ::/0`, and that's intentional. The router's GL route policy decides what goes into wg3, not the WireGuard config. The main routing table only holds routes to jennie's own addresses (`172.31.1.9`, `192.168.254.2`, `fd33:5692:1834:ff03::1`, `fd33:5692:1834:254::2`). Table 1002 has a default route via wg3, but only traffic the policy marks (`0x2000`) uses it, so home traffic isn't sent to jennie by default.

Today the policy is the `UK` rule (tunnel 6611). Its targets are in `/etc/domain_mac_list/dst_net6611_manual`: 28 BBC domains, resolved by the router's dnsmasq, plus jennie's `192.168.254.2` and `fd33:5692:1834:254::2`. Traffic into wg3 is masqueraded to `fd33:5692:1834:ff03::2` as described above.

Two things to know about this setup:

- **Domain-based policy only sees DNS that goes through the router.** A device using its own DNS (browser DNS-over-HTTPS, iCloud Private Relay, a hard-coded resolver) gets BBC addresses dnsmasq never sees, so that traffic isn't marked and leaves via the ISP. If BBC checks fail on one device, check its DNS first.
- **The IPv6 masquerade should skip VPN sources.** Translation is only needed for ISP-sourced traffic. A plain `-o wgclient2 -j MASQUERADE` also rewrites home hosts' ULA traffic to jennie (for example to `fd33:5692:1834:254::2`), so jennie sees `ff03::2` instead of the real host. Add `! -s fd33:5692:1834::/48` to the rule (Task 4c).

***

## Firewall on ruby

ruby's firewall is the hand-written `/etc/nftables.conf` (`table inet filter`, plus `table ip wgnat` for client NAT). Docker manages its own `ip`/`ip6` tables through iptables-nft. The live ruleset dumped to `ruby/current-nft-ruleset` matches the file.

`ruby/nftables.conf` is the proposed new version. `ruby/nftables.conf.diff` shows exactly what changes against the live file. It passes `nft -c`. The changes:

| Area | Change |
|------|--------|
| `define`s | `WGIFS = { "wg0", "wg1", "wg2" }`, `DOCKERNET6`, `JENNIE6` |
| input | UDP 51821 accepted on `$PUB6` from anywhere (home has a dynamic address); UDP 51822 on `$PUB6` only from jennie |
| input | The VPN-side service rules (SSH, DNS, web, mail submission/IMAP/Sieve, mosh) now apply to all `$WGIFS`, not just wg0. The firewall then lets home LANs and jennie through, but most of those services still only accept clients (see [Service allow lists](#service-allow-lists)) |
| input | Removed: the `wg0` rule for TCP 19080. The WordPress container is now published on loopback only and reached through the host nginx on 80/443 (see the end of this README) |
| forward | `wg0 ↔ wg0` accept becomes `$WGIFS ↔ $WGIFS`: anything in the VPN reaches anything else |
| forward | The "no route into Docker or other private space" drops now apply to all tunnels, and gain an IPv6 rule for Docker's `fda6:50ae:40f0::/64` |
| forward | New: `ens3 → $WGIFS` drop. Under the accept policy, nothing previously stopped the internet side from starting connections into the VPN |
| forward | New: IPv6 from any tunnel to ens3 is dropped (no NAT66) |
| nat | Unchanged: IPv4 `wgnat` only; comment notes there is deliberately no NAT66 |

### Service allow lists

DNS, mail submission and ManageSieve on ruby are open to **everything on the VPN**: clients, the home LANs, jennie and the tunnel links, over IPv4 and IPv6. The services are reached at the wg0 addresses (`192.168.204.254`, `fd33:5692:1834:204::254`), which every site already routes to ruby. Task 5e (`ruby/services/`) makes the changes:

| Service | What limits it | Change |
|---------|----------------|--------|
| BIND | listen addresses, plus the `wireguard` view's `match-clients` and ACLs (`192.168.204.0/24` only) | new `acl "vpn"` used by the view and all its ACLs; also listens on `fd33:5692:1834:204::/64` |
| Postfix submission/smtps | the bind address only; it requires SMTP AUTH from every source (the VPN is deliberately absent from `mynetworks`) | also binds `[fd33:5692:1834:204::254]` (the IPv6 services `master.cf` already had prepared) |
| Dovecot ManageSieve | the listen addresses only; it requires TLS and auth from every source | also listens on `fd33:5692:1834:204::254` and `fd33:5692:1834:254::254` |
| Dovecot IMAPS | none (`*, ::`) | none |
| nftables | `$WGIFS` input rules (Task 2b, live) | none |

`acl "vpn"` in `named.conf.local`:

| Range | What |
|-------|------|
| `192.168.204.0/24` | wg0 clients |
| `192.168.8.0/21` | home LANs |
| `192.168.254.0/24` | site service addresses (dummies) |
| `172.31.1.0/24` | tunnel links: jennie's and the home router's own queries leave from their tunnel address |
| `fd33:5692:1834::/48` | the whole VPN ULA prefix |

The `wireguard` view also resolves the lab's internal names. `home` and `8.168.192.in-addr.arpa` are `static-stub` zones pointing at Pythia (`192.168.8.52`), the lab's authoritative server, reached over wg1. They don't go to Themis or Delphi because those only accept queries from the home LAN and the Proxmox lab networks. `disable-empty-zone "168.192.in-addr.arpa"` stops BIND's built-in RFC 1918 empty zone answering the lab's PTRs first. No DNSSEC exception is needed because ruby doesn't validate (`dnssec-validation no`). Check with `dig @192.168.204.254 pythia.home` from a client.

Home hosts reach ruby over IPv6 from their **ULA** address (the router advertises a ULA `/64`; see [Home LANs and the ISP's IPv6](#home-lans-and-the-isps-ipv6)). Their ISP address isn't in wg1's allowed IPs, so it never gets through. That's by design.

Start order: Postfix and Dovecot bind specific addresses, which must exist when they start, so Task 5e also makes both wait for systemd-networkd to finish configuring wg0 (and dummy0 for Dovecot):

- **Dovecot:** its existing drop-in ordered it after `wg-quick@wg0`, which no longer applies once wg0 moves to netplan. It now waits for `systemd-networkd-wait-online@wg0:routable` and `@dummy0:routable`.
- **Postfix:** a new drop-in does the same for wg0. Postfix had none, so it was only ordered after `network.target`, which waits for no interface. With wg-quick, it already risked failing to bind `192.168.204.254` at boot.

Left as they are (see [TASKS.md](TASKS.md), follow-ups):

- **Postfix's CIDR table** (`wireguard_clients.cidr`) isn't referenced anywhere, although `main.cf`'s comments say it rejects sources outside `192.168.204.0/24`. The real gate is binding only the wg0 addresses, plus SASL. `main.cf`'s header still describes the VPN as `192.168.204.0/24 (wg0)`.
- **The split-horizon `mail.peetvandesande.com`** has only an A record, so mail keeps going over IPv4. That's fine, since hosts prefer IPv4 over ULA anyway.

### Docker's IPv6 forward policy is DROP

Docker runs with `"ip6tables": true`, so its `ip6 filter` FORWARD chain has **policy drop**. As the header of `nftables.conf` explains, a drop in any chain on the forward hook wins, so accepts in `nftables.conf` can't override it. **All IPv6 forwarding through ruby is currently dropped.** That wasn't visible before because nothing in the VPN used IPv6.

`ruby/wg-docker-user.service` fixes this by adding narrow accepts to Docker's `DOCKER-USER` chain:

- **IPv6:** tunnel ↔ tunnel only. With no NAT66, IPv6 never goes from a tunnel to the internet.
- **IPv4:** tunnel ↔ tunnel, tunnel → ens3, and ens3 → tunnel for established/related traffic. IPv4's policy is currently accept, so these are insurance. It runs after dockerd, re-runs whenever Docker restarts (`PartOf=docker.service`), and checks before inserting, so rules never duplicate. Nothing in it touches traffic to containers, so Docker's isolation still applies.

### Applying firewall changes

Use **`systemctl reload nftables`**, never `restart`. The unit's `ExecStop` is `nft flush ruleset`, which wipes Docker's tables as well, and container networking stays broken until dockerd restarts. `reload` re-runs the file, whose declare-then-delete idiom only replaces ruby's own tables.

***

## Firewall on jennie

jennie had no firewall. `jennie/nftables.conf` follows ruby's conventions (inet tables, declare-then-delete, no `flush ruleset`) rather than using UFW. UFW's default forward policy is drop, and NAT, especially NAT66, can only be added by hand-editing its `before.rules`/`before6.rules`. For a NAT exit it ends up being nftables underneath anyway, split across two syntaxes.

| Chain | Policy | Rules |
|-------|--------|-------|
| input | drop | loopback; established/related; ICMP and the ICMPv6 essentials; DHCPv4/DHCPv6 replies from OVH; SSH; UDP 51822 from ruby's IPv6 only; UDP 51823 from anywhere (home is dynamic); UDP 51820 (wg0, clients) from anywhere on both families; everything from wg2/wg3; a placeholder for public services |
| forward | drop | MSS clamping; wg ↔ wg; wg → ens3; ens3 → wg for established/related only |
| output | accept | none |
| nat (`inet wgnat`) | n/a | snat VPN IPv4 sources to `57.129.180.73` and VPN IPv6 (`fd33:5692:1834::/48`) to `2001:41d0:801:2000::180f`, on ens3 only |

The forward chain can use a drop policy here, unlike on ruby, because jennie has no Docker bridges.

***

## Clients on jennie

mba, mbp and iphone-peet each have a second tunnel, to jennie's `wg0` on the standard port 51820, so they can still reach home, ruby and the internet when ruby is down. The two tunnels are alternatives: a device runs one or the other, and the WireGuard apps only bring up one at a time anyway.

- **Keys:** each device reuses the key pair it has on ruby. WireGuard allows one key to have peers on several servers. Each peer gets a fresh PSK on jennie.
- **Addresses:** `192.168.205.0/24` and `fd33:5692:1834:205::/64`, with the same host number as on ruby.
- **Endpoint:** jennie's public IPv4 *and* IPv6. Unlike the site-to-site tunnels, wg0 listens on both, since mobile networks are often IPv4-only.
- **Reach:** home over wg3 and ruby over wg2, both direct from jennie. The other ends need routes back to `192.168.205.0/24` and `fd33:5692:1834:205::/64`. On ruby they're main-table routes in `82-wireguard-wg2.yaml`. On the router they're two policy rules at priority 19000 into table 1002, like the existing `s2s_*` rules (`router/README.md`). The router's firewall already accepts wgclient2 → lan.
- **Internet:** exits via jennie with NAT44 and NAT66, both families, for every client. Nothing needs opting in.

### DNS on jennie

jennie runs its own BIND (`jennie/services/etc/bind/`), so jennie's clients don't depend on ruby for names. It gives the same answers as ruby's `wireguard` view:

- **Split-horizon zones:** byte-for-byte copies of ruby's `/etc/bind/wireguard/` files, plus a reverse zone for `192.168.205.0/24`. Change them on both hosts together. The answers still point at ruby (`192.168.204.254`), so mail follows ruby's availability, but resolving names doesn't.
- **`home.` and the lab's reverse zone:** `static-stub` to Pythia over wg3, as on ruby.
- **No views.** jennie has no Docker clients to tell apart from the VPN, so Debian's own `named.conf` and default zones stay. The same `acl "vpn"` as ruby's, plus jennie's clients, gates every query.
- **Validating**, unlike ruby, which turns validation off for Postfix's DANE. `home.` and `8.168.192.in-addr.arpa` are unsigned, so they're listed in `validate-except`.
- **Listens on** `192.168.205.254`, `fd33:5692:1834:205::254`, jennie's dummy0 addresses and loopback, never ens3.

### Client config

Add a second tunnel on each device, e.g. `jennie`, next to the existing one:

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

The steps are TASKS.md phase 8.

***

## Files in this directory

| File | Install on | Destination | Purpose |
|------|------------|-------------|---------|
| `ruby/70-dummy-interfaces.yaml` | ruby | `/etc/netplan/` | Replaces the live file: dummy0/dummy1 with the renumbered IPv6 addresses |
| `ruby/80-wireguard-wg0.yaml` | ruby | `/etc/netplan/` | wg0, clients |
| `ruby/81-wireguard-wg1.yaml` | ruby | `/etc/netplan/` | wg1, to home |
| `ruby/82-wireguard-wg2.yaml` | ruby | `/etc/netplan/` | wg2, to jennie |
| `ruby/nftables.conf` | ruby | `/etc/nftables.conf` | Proposed firewall with the WireGuard changes |
| `ruby/nftables.conf.diff` | none | none | Diff of the above against the live `/etc/nftables.conf` |
| `ruby/nftables.conf.orig` | none | none | Copy of the live `/etc/nftables.conf` the draft was made from |
| `ruby/networkd-forwarding.conf` | ruby | `/etc/systemd/networkd.conf.d/forwarding.conf` | IPv4/IPv6 forwarding owned by networkd (IPv6 currently only on because of Docker) |
| `ruby/wg-docker-user.service` | ruby | `/etc/systemd/system/` | IPv4/IPv6 `DOCKER-USER` accepts for WireGuard forwarding |
| `ruby/services/etc/…` | ruby | same path under `/etc` | BIND, Postfix and Dovecot configs with IPv6 listeners, plus systemd start-order drop-ins (Task 5e) |
| `ruby/services/orig/etc/…` | none | none | The live originals those were made from (2026-10-09) |
| `ruby/services/services.diff` | none | none | All service changes as one diff |
| `ruby/current-nft-ruleset` | none | none | Dump of ruby's live ruleset (2026-10-08), for reference |
| `jennie/70-dummy0.yaml` | jennie | `/etc/netplan/` | dummy0 with `192.168.254.2`, `fd33:5692:1834:254::2` |
| `jennie/80-wireguard-wg0.yaml` | jennie | `/etc/netplan/` | wg0, clients |
| `jennie/82-wireguard-wg2.yaml` | jennie | `/etc/netplan/` | wg2, to ruby |
| `jennie/83-wireguard-wg3.yaml` | jennie | `/etc/netplan/` | wg3, to home |
| `jennie/networkd-forwarding.conf` | jennie | `/etc/systemd/networkd.conf.d/forwarding.conf` | IPv4/IPv6 forwarding (internet exit), owned by networkd |
| `jennie/nftables.conf` | jennie | `/etc/nftables.conf` | jennie's whole firewall, including the exit's forwarding rules and NAT44/NAT66 |
| `jennie/services/etc/bind/…` | jennie | same path under `/etc` | BIND for jennie's clients, with copies of ruby's split-horizon zones |
| `home/wg1.conf` | home | router UI | wg1 settings in wg-quick format, as a reference |
| `home/wg3.conf` | home | router UI | wg3 settings in wg-quick format, as a reference |
| `fill-secrets.py` | none | none | Fills key/PSK placeholders (see Task 1) |
| `wg1.key`, `wg1.pub`, `wg2.key`, `wg2.pub` | none | none | ruby's new wg1/wg2 keypairs |
| `jennie.psk`, `home-jennie.psk` | none | none | PSKs for wg2 and wg3 |
| `superseded/` | none | none | The earlier wg-quick versions, kept for reference. Not used. |

The ruby files are split one per tunnel so they can be installed in stages. wg1 can't go live while the old wg0 still holds the `192.168.8.0/21` route.

ruby's live `/etc/wireguard/wg0.conf` is **never modified**. The migration only stops `wg-quick@wg0`, which keeps rollback simple.

***

## Tasks

These tasks ran on ruby from a copy of this directory (`cd ~/wg`), and on jennie from `~/wg-jennie`, unless marked *on home*. They are kept as the record of how it was done. Since then ruby and jennie each have a clone of the repo at `~/homelab`: new work runs from `~/homelab/wireguard`, and secrets are filled into the installed copy under `/etc`, never into the clone (see TASKS.md).

Order:

1. Fill in ruby's secrets.
2. Update ruby's firewall, and open ports on jennie.
3. ruby ↔ jennie (wg2).
4. jennie ↔ home (wg3).
5. Move ruby's wg0 to netplan and home to wg1.
6. Update clients.
7. Test everything.

Clients on jennie are independent of this order and have no section here: the steps are TASKS.md phase 8, and the design is [Clients on jennie](#clients-on-jennie).

Step 2 changes nothing for traffic that works today; the new rules only match interfaces and ports that aren't in use yet. Steps 3 and 4 add new tunnels and don't touch anything running. Step 5 is the only one with downtime.

### Task 1: Fill in secrets

**1a. ruby's existing wg0 key and PSKs, from the backup of the live config.**

```bash
sudo cat /etc/wireguard.bak-2026-10-08/wg0.conf | ./fill-secrets.py
```

This fills ruby's wg0 private key, the PSKs for mba, iphone-peet and mbp, and home's PSK (in `ruby/81-wireguard-wg1.yaml` and `home/wg1.conf`). It never prints secrets.

If it prints `live hook: …` lines, the old wg0 has `PostUp`/`PostDown` commands that stop running once wg-quick is retired. Client NAT and the forward rules are already in `/etc/nftables.conf`, so there probably aren't any. If there are, check whether `nftables.conf` or `wg-docker-user.service` already covers them before carrying anything over.

**1b. Check what's left.** Run `./fill-secrets.py </dev/null` at any time. After 1a, the only placeholders left should be:

- `jennie/*`: jennie's private keys and home's wg3 public key (filled on jennie in Tasks 3 and 4)
- `home/*`: router-side values (the router's own keys, and jennie's wg3 public key from Task 4)

### Task 2: Firewalls and forwarding

**2a. ruby: forwarding.** It's on in both families today, but not pinned down:

- **IPv4** is set by `/etc/systemd/network/10-netplan-ens3.network.d/networkd-ipforward.conf`.
- **IPv6** is only on because dockerd enables it.

On a networkd host, forwarding belongs in networkd itself (systemd 257 here), so make it global and explicit:

```bash
sudo install -D -m 644 ruby/networkd-forwarding.conf /etc/systemd/networkd.conf.d/forwarding.conf
sudo systemctl restart systemd-networkd    # re-reads networkd.conf; keeps existing addresses and tunnels
cat /proc/sys/net/ipv4/conf/all/forwarding /proc/sys/net/ipv6/conf/all/forwarding   # 1 and 1
```

**2b. ruby: nftables.** Review `ruby/nftables.conf.diff` (summarised in [Firewall on ruby](#firewall-on-ruby)), then install it:

```bash
sudo cp -a /etc/nftables.conf /etc/nftables.conf.bak-$(date +%F)
cmp /etc/nftables.conf ruby/nftables.conf.orig \
  && echo "live file unchanged since the draft" || echo "LIVE FILE CHANGED: redo the edits"
sudo install -m 755 -o root -g root ruby/nftables.conf /etc/nftables.conf
sudo nft -c -f /etc/nftables.conf && sudo systemctl reload nftables     # reload, NOT restart
sudo nft list table inet filter | grep -E 'WGIFS|wg[0-2]|51821|51822'
sudo iptables -S | grep -c DOCKER                                       # Docker's rules still there
```

Use `reload`, not `restart`; see [Applying firewall changes](#applying-firewall-changes). The `cmp` check guards against the live file having been edited since this draft was made. If it says the live file changed, redo the edits on the new version instead of overwriting it.

**2c. ruby: Docker's DOCKER-USER exceptions.** These are needed for any IPv6 forwarding (see [Docker's IPv6 forward policy is DROP](#dockers-ipv6-forward-policy-is-drop)):

```bash
sudo install -m 644 -o root -g root ruby/wg-docker-user.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wg-docker-user.service
sudo ip6tables -S DOCKER-USER; sudo iptables -S DOCKER-USER             # three wg+ rules each
```

**2d. jennie: firewall and forwarding.** *On jennie.* jennie has no firewall yet, so `jennie/nftables.conf` becomes its whole firewall. The input policy is drop, so first check what jennie serves publicly:

```bash
sudo ss -tulpn | grep -vE '127\.0\.0\.|\[::1\]'   # anything listening beyond localhost
systemctl is-active docker                          # expected: inactive (see below if not)
```

- SSH (22) and WireGuard (51822 from ruby, 51823 from anywhere) are already allowed, over IPv6.
- Add a rule under "Public services" in `nftables.conf` for anything else that must stay reachable from the internet.
- Everything arriving over wg2/wg3 is accepted.
- If Docker turns out to be installed, stop and adapt first: its IPv6 FORWARD policy is drop (as on ruby), and jennie would need a copy of `ruby/wg-docker-user.service`, also allowing IPv6 `wg+ → ens3`.

Copy the files over (*run on ruby*):

```bash
scp ~/wg/jennie/networkd-forwarding.conf ~/wg/jennie/nftables.conf jennie:wg-jennie/
```

Enable forwarding (*on jennie*):

```bash
systemctl --version | head -1              # needs systemd >= 256 for IPv4Forwarding=/IPv6Forwarding=
sudo install -D -m 644 ~/wg-jennie/networkd-forwarding.conf /etc/systemd/networkd.conf.d/forwarding.conf
sudo systemctl restart systemd-networkd
cat /proc/sys/net/ipv4/conf/all/forwarding /proc/sys/net/ipv6/conf/all/forwarding   # 1 and 1
ip -6 route show default                   # still there (networkd handles RAs itself)
```

Apply the firewall with a **dead-man switch**: a timer that removes it again after 3 minutes, unless you cancel the timer from a *new* SSH session that proves you're not locked out.

```bash
sudo cp -a /etc/nftables.conf /etc/nftables.conf.bak-$(date +%F) 2>/dev/null   # Debian ships a stub
sudo install -m 755 -o root -g root ~/wg-jennie/nftables.conf /etc/nftables.conf
sudo nft -c -f /etc/nftables.conf && echo "syntax OK"
sudo systemd-run --on-active=180 --unit=nft-deadman /usr/sbin/nft delete table inet filter
sudo nft -f /etc/nftables.conf
# now open a NEW ssh session to jennie; if it works:
sudo systemctl stop nft-deadman.timer
sudo systemctl enable --now nftables       # load it at boot
sudo nft list ruleset | head -40
```

If the new session doesn't connect, wait 3 minutes: the timer deletes `inet filter` (input drop policy and forward rules) and access returns. The NAT table stays but does nothing harmful on its own.

Later changes: `sudo nft -c -f /etc/nftables.conf && sudo systemctl reload nftables`. Never `restart`, as on ruby.

**2e. ruby: renumber the dummy interfaces' IPv6.** `fd00::1` → `fd33:5692:1834:254::254` (dummy0) and `fd00::2` → `fd33:5692:1834:254::253` (dummy1). Nothing listens on the old addresses (checked with `ss`), and rspamd's `local_addrs` (`fd00::/8`) already covers the new ones. Do this before clients get IPv6 addresses (Task 6), so nothing ever uses the old addresses.

`ruby/70-dummy-interfaces.yaml` was written from the live addresses, because the live file isn't readable without root. Compare first; only the two IPv6 lines (and comments) should differ:

```bash
sudo diff /etc/netplan/70-dummy-interfaces.yaml ruby/70-dummy-interfaces.yaml
sudo cp -a /etc/netplan/70-dummy-interfaces.yaml /etc/netplan/70-dummy-interfaces.yaml.bak-$(date +%F)   # netplan only reads *.yaml
sudo install -m 600 -o root -g root ruby/70-dummy-interfaces.yaml /etc/netplan/
sudo netplan generate
sudo networkctl reload && sudo networkctl reconfigure dummy0 dummy1
ip -br addr show dummy0; ip -br addr show dummy1                          # new IPv6 only, no fd00::
```

If an old `fd00::` address lingers, remove it with `sudo ip -6 addr del fd00::1/128 dev dummy0` (and `fd00::2/128` on dummy1).

jennie's `82-wireguard-wg2.yaml` has the new addresses in its allowed IPs and routes. If you already installed an earlier copy on jennie, reinstall it there and recreate wg2: `sudo netplan generate && sudo ip link del wg2 && sudo networkctl reload`.

**2f. Provider firewalls.** Neither server has one (no OVH network firewall or security groups), so jennie's and ruby's nftables are the only filtering.

### Task 3: ruby ↔ jennie (wg2)

*On jennie.* Copy the files over and fill in jennie's wg2 key:

```bash
scp -r ~/wg/jennie jennie:wg-jennie        # run on ruby
```

```bash
# on jennie
cd ~/wg-jennie
sudo apt install wireguard-tools           # for the wg command; networkd does the tunnel itself
sed -i "s|<jennie wg2 private key>|$(sudo cat /etc/wireguard/jennie.key)|" 82-wireguard-wg2.yaml
#      ^ wherever jennie's wg2 private key was saved earlier
grep -n '<' 70-dummy0.yaml 82-wireguard-wg2.yaml || echo "wg2 files filled"
```

Check whether jennie already has a `dummy0`, and see what netplan files exist:

```bash
ip -br link show type dummy; ls -l /etc/netplan/
```

If `dummy0` is taken, rename it in `70-dummy0.yaml` (e.g. `dummy1`).

Install and bring up dummy0 and wg2:

```bash
# on jennie
sudo install -m 600 -o root -g root 70-dummy0.yaml 82-wireguard-wg2.yaml /etc/netplan/
sudo netplan generate
sudo networkctl reload
ip -br addr show dummy0; ip -br addr show wg2
```

*On ruby:*

```bash
sudo install -m 600 -o root -g root ruby/82-wireguard-wg2.yaml /etc/netplan/
sudo netplan generate
sudo networkctl reload
sudo wg show wg2      # recent handshake; endpoint [2001:41d0:801:2000::180f]:51822
```

`networkctl reload` creates the new interfaces without touching existing ones. `sudo netplan apply` also works, but it reconfigures every netplan-managed interface (including ens3).

Test from ruby:

```bash
ping -c3 172.31.1.6
ping -c3 fd33:5692:1834:ff02::2
ping -c3 192.168.254.2
ping -c3 fd33:5692:1834:254::2
ping -M do -c3 -s 1392 172.31.1.6               # MTU: 1420 - 28
ping -M do -c3 -s 1372 fd33:5692:1834:ff02::2   # MTU: 1420 - 48
```

### Task 4: jennie ↔ home (wg3)

This links the home LANs directly to jennie and doesn't affect anything else.

**4a. Keys.** On jennie, generate jennie's wg3 key:

```bash
# on jennie
(umask 077; wg genkey | sudo tee /etc/wireguard/wg3.key | wg pubkey)
cd ~/wg-jennie
sed -i "s|<jennie wg3 private key>|$(sudo cat /etc/wireguard/wg3.key)|" 83-wireguard-wg3.yaml
```

On home, create a **new WireGuard interface** for wg3 with its own key; most routers generate one when you create the interface. Then swap public keys:

```bash
# on jennie: home's wg3 public key
sed -i "s|<home wg3 public key>|PASTE_HOME_INET_WG3_PUBKEY|" 83-wireguard-wg3.yaml

# on ruby: jennie's wg3 public key, into the router reference
sed -i "s|<jennie wg3 public key>|PASTE_JENNIE_WG3_PUBKEY|" home/wg3.conf
```

**4b. jennie.**

```bash
# on jennie
grep -n '<' 83-wireguard-wg3.yaml || echo "wg3 file filled"
sudo install -m 600 -o root -g root 83-wireguard-wg3.yaml /etc/netplan/
sudo netplan generate
sudo networkctl reload
```

wg3 also gives jennie the lab's internal names. Its `nameservers` block sends `home.` and `8.168.192.in-addr.arpa` to Pythia (`192.168.8.52`) as routing-only domains, so systemd-resolved queries Pythia over wg3 for those names and nothing else. This goes direct, like all of jennie's traffic to home, rather than via ruby's stub zones. Themis and Delphi would refuse jennie's queries. If wg3 is down, `.home` stops resolving, but the lab is unreachable then anyway. Check with `resolvectl query pythia.home`.

**4c. home router.** Configure the new interface from `home/wg3.conf`:

| Setting              | Value |
|----------------------|-------|
| Interface            | new, e.g. `wg3` |
| Private key          | new, generated on the router (4a) |
| Tunnel address       | `172.31.1.10/30`, `fd33:5692:1834:ff03::2/64` |
| MTU                  | `1388` |
| Peer public key      | jennie's wg3 public key (4a) |
| Preshared key        | contents of `home-jennie.psk` (already in `home/wg3.conf`) |
| Endpoint             | `[2001:41d0:801:2000::180f]:51823` |
| Persistent keepalive | `25` |
| Peer allowed IPs     | `0.0.0.0/0, ::/0` (jennie is an internet exit) |
| Automatic routes     | **off** (wg-quick: `Table = off`). The router's GL client installs its default only in table 1002, so main-table traffic is unaffected |
| Routes via wg3       | `172.31.1.9/32`, `192.168.254.2/32`, `fd33:5692:1834:ff03::1/128`, `fd33:5692:1834:254::2/128`, as persistent `route`/`route6` entries on `wgclient2` |
| Internet via jennie  | GL route policy `UK` (tunnel 6611, mark `0x2000`), with targets in `/etc/domain_mac_list/dst_net6611_manual`. Table 1002 holds the default route via wg3 (IPv4 and IPv6). Other clients or destinations can be added as further policy rules |
| IPv6 NAT             | `ip6tables -t nat` MASQUERADE on `wgclient2`, in `/etc/firewall.user` (no IPv4 NAT). **Recommended:** limit it to non-VPN sources, so only ISP-sourced traffic is translated: `ip6tables -t nat -A POSTROUTING -o wgclient2 ! -s fd33:5692:1834::/48 -j MASQUERADE` |

**4d. Test.**

```bash
# on jennie
sudo wg show wg3                           # handshake from the router's IPv6 address
ping -c3 172.31.1.10
ping -c3 fd33:5692:1834:ff03::2
ping -c3 192.168.8.1                       # or any home LAN host
traceroute -n 192.168.8.1                  # first hop 172.31.1.10, not via ruby
ping -M do -c3 -s 1360 172.31.1.10         # MTU: 1388 - 28
```

If the MTU ping fails but smaller sizes work, the home link has a lower MTU. Lower it on both ends of wg3 (and wg1).

### Task 5: Move wg0 to netplan, move home to wg1

This is the only step with downtime:

- **Clients** drop for a few seconds while wg0 is recreated.
- **home ↔ ruby** is down from the moment wg0 stops until the router's wg1 is configured. home ↔ jennie keeps working over wg3.

Have the router settings from 5a ready before starting.

**5a. Prepare these settings on the home router.** Convert its existing tunnel to ruby into wg1, using `home/wg1.conf`:

| Setting              | Value |
|----------------------|-------|
| Interface            | the existing tunnel to ruby (rename to `wg1` if the router allows) |
| Private key          | **unchanged** (ruby's wg1 expects the router's existing public key, `vQww1GLu…`) |
| Tunnel address       | `172.31.1.2/30`, `fd33:5692:1834:ff01::2/64` (remove the old `192.168.204.5`) |
| MTU                  | `1388` |
| Peer public key      | ruby's wg1 key: `UFJld/qzjF6JzLwIVxayR48jfkZgTmTXhyPlK6txDCc=` |
| Preshared key        | **unchanged** (already in `home/wg1.conf` after Task 1a) |
| Endpoint             | `[2001:41d0:305:2100::1:3a0e]:51821` |
| Persistent keepalive | `25` |
| Peer allowed IPs     | `172.31.1.1/32, fd33:5692:1834:ff01::1/128, 192.168.204.0/24, fd33:5692:1834:204::/64, 192.168.254.253/32, 192.168.254.254/32, fd33:5692:1834:254::254/128, fd33:5692:1834:254::253/128` |
| Routes via wg1       | the same, minus the two transit addresses, if the router doesn't add routes from allowed IPs |
| LAN IPv6             | **Done** for lan (`fd33:5692:1834:1000::/64`) and iot (`…:1001::/64`), and guest (`…:1002::/64`, disabled). The ISP prefixes are kept (see [Home LANs and the ISP's IPv6](#home-lans-and-the-isps-ipv6)) |

Remove any old routes on the router that pointed jennie's or ruby's networks at the old tunnel.

**5b. Install on ruby.** The files go in place first; nothing changes until wg-quick is stopped.

```bash
sudo install -m 600 -o root -g root ruby/80-wireguard-wg0.yaml ruby/81-wireguard-wg1.yaml /etc/netplan/
sudo netplan generate && echo "netplan OK"
```

**5c. Cut over.**

```bash
sudo systemctl disable --now wg-quick@wg0  # removes wg0 and its routes, runs its PostDown
sudo networkctl reload                     # networkd creates wg0 and wg1
```

Then apply the router settings from 5a.

**5d. Check from ruby.**

```bash
networkctl list                            # wg0, wg1, wg2: routable / configured
sudo wg show                               # wg0 clients reconnecting; wg1 handshake from an IPv6 address
ip route | grep -E 'wg[0-2]'
ip -6 route | grep -E 'wg[0-2]'
ping -c3 172.31.1.2
ping -c3 fd33:5692:1834:ff01::2
ping -c3 192.168.8.1                       # or any home LAN host
ping -c3 <a home host's ULA address>
ping -M do -c3 -s 1360 172.31.1.2          # MTU: 1388 - 28
```

**5e. IPv6 for BIND, Postfix and Dovecot.** Do this right after 5c. It needs wg0's IPv6 address (5c) and dummy0's renumbered address (Task 2e), and the Dovecot drop-in it replaces still refers to wg-quick. Review `ruby/services/services.diff` first.

Check the live files haven't changed since the copies were taken:

```bash
cd ~/wg/ruby/services
for f in $(cd orig && find etc -type f); do cmp -s "orig/$f" "/$f" && echo "unchanged: /$f" || echo "CHANGED:   /$f  (redo the edit on the new version)"; done
```

Start-order drop-ins. These change nothing until the next restart:

```bash
sudo install -m 644 etc/systemd/system/dovecot.service.d/dovecot-local-deps.conf /etc/systemd/system/dovecot.service.d/
sudo install -D -m 644 etc/systemd/system/postfix@-.service.d/local-deps.conf /etc/systemd/system/postfix@-.service.d/local-deps.conf
sudo systemctl daemon-reload
systemctl show -p After dovecot postfix@- | grep -o 'systemd-networkd-wait-online@[^ ]*'
```

BIND (picks up the new address without restarting):

```bash
sudo install -m 644 -o root -g bind etc/bind/named.conf.options etc/bind/named.conf.local /etc/bind/
sudo named-checkconf && sudo rndc reconfig
ss -ulnH 'sport = :53' | grep fd33          # [fd33:5692:1834:204::254]:53
```

Postfix:

```bash
sudo install -m 644 etc/postfix/master.cf /etc/postfix/master.cf
sudo postfix check && sudo systemctl restart postfix
ss -ltnH | grep -E ':(587|465)\b'           # 192.168.204.254 and [fd33:5692:1834:204::254], both ports
```

Dovecot:

```bash
sudo install -m 644 etc/dovecot/conf.d/20-managesieve.conf /etc/dovecot/conf.d/
sudo doveconf -n >/dev/null && sudo systemctl reload dovecot
ss -ltnH 'sport = :4190'                    # four addresses; if the IPv6 ones are missing: sudo systemctl restart dovecot
```

From a client with its IPv6 address (Task 6):

```bash
dig @fd33:5692:1834:204::254 mail.peetvandesande.com +short                      # 192.168.204.254
openssl s_client -connect '[fd33:5692:1834:204::254]:465' -brief </dev/null       # TLS handshake OK
nc -zv fd33:5692:1834:204::254 587 && nc -zv fd33:5692:1834:204::254 4190
```

From jennie and from a home LAN host (once wg1 and wg2/wg3 are up):

```bash
dig @192.168.204.254 mail.peetvandesande.com +short                              # 192.168.204.254 (split horizon)
dig @fd33:5692:1834:204::254 mail.peetvandesande.com +short                      # same, over IPv6
nc -zv 192.168.204.254 587 && nc -zv 192.168.204.254 4190
```

### Task 6: Update the clients

Each client keeps its keys, PSK and endpoint. Only `Address` and `AllowedIPs` change:

```ini
[Interface]
Address = 192.168.204.1/32, fd33:5692:1834:204::1/128     # mba; iphone-peet .2 / ::2, mbp .4 / ::4
```

Pick one `AllowedIPs` line:

```ini
# Full tunnel: IPv4 internet via ruby (or jennie, if opted in on ruby), IPv6 internet via jennie
AllowedIPs = 0.0.0.0/0, ::/0

# VPN networks only
AllowedIPs = 192.168.204.0/24, 192.168.8.0/21, 192.168.254.2/32, 192.168.254.253/32, 192.168.254.254/32, fd33:5692:1834:204::/64, fd33:5692:1834:1000::/56, fd33:5692:1834:254::2/128, fd33:5692:1834:254::254/128, fd33:5692:1834:254::253/128
```

The split-tunnel list only contains networks ruby actually routes. Clients don't need the `172.31.1.0/24` transit addresses.

Which exit a client uses isn't set on the client: it's decided by ruby's routing-policy rules (see [Internet exits](#internet-exits)).

Test from a client:

```bash
ping 192.168.204.254 && ping6 fd33:5692:1834:204::254   # ruby
ping 192.168.254.2   && ping6 fd33:5692:1834:254::2     # jennie, via ruby
ping 192.168.8.1                                         # home, via ruby
curl -4 https://ifconfig.co                              # full tunnel: 46.105.253.72 (ruby), or 57.129.180.73 if opted in to jennie
curl -6 https://ifconfig.co                              # full tunnel: 2001:41d0:801:2000::180f (jennie)
```

### Task 7: Test end to end and reboot

```bash
# on jennie
ping -c3 192.168.204.1                     # a client, via ruby (wg2)
ping -c3 fd33:5692:1834:204::1
ping -c3 192.168.254.254                   # ruby's dummy0
traceroute -n 192.168.8.1                  # direct over wg3 (first hop 172.31.1.10)

# from a home LAN host
traceroute -n 192.168.204.1                # via ruby (172.31.1.1)
traceroute -n 192.168.254.2                # via jennie (172.31.1.9)

# from a home host the router sends via jennie (e.g. the laptop)
curl -4 https://ifconfig.co                # 57.129.180.73
curl -6 https://ifconfig.co                # 2001:41d0:801:2000::180f

# on ruby: the exit policy
ip rule; ip -6 rule                        # priorities 900 (main) and 1000 (table 200)
ip route show table 200; ip -6 route show table 200

# on jennie: NAT counters go up as exit traffic flows
sudo nft list table inet wgnat
```

Reboot ruby and jennie (one at a time) to confirm everything comes back on its own (netplan, nftables, `wg-docker-user.service`):

```bash
networkctl list; sudo wg show; sudo ip6tables -S DOCKER-USER; sudo iptables -S DOCKER-USER   # ruby
networkctl list; sudo wg show; sudo nft list tables; cat /proc/sys/net/ipv4/conf/all/forwarding /proc/sys/net/ipv6/conf/all/forwarding   # jennie
```

### Task 8: Clean up

```bash
# on ruby, once everything has run fine for a while
shred -u ~/wg/wg1.key ~/wg/wg2.key ~/wg/jennie.psk ~/wg/home-jennie.psk
# the filled YAML/conf files in ~/wg also contain secrets: shred them, or keep ~/wg as a 700 directory

# on jennie
shred -u ~/wg-jennie/*.yaml
```

The old `/etc/wireguard/wg0.conf` on ruby is no longer used. Keep it until you're confident you won't roll back, then remove it along with `/etc/wireguard.bak-2026-10-08`.

Remove sylvie from any other place it's referenced (DNS, monitoring).

***

## Rollback

**ruby: back to wg-quick wg0.** No longer possible as written: Task 8 removed `/etc/wireguard/wg0.conf` and its backup. Kept for reference; restore the config from `~/projects/homelab-private/wireguard/superseded/` first if it's ever needed:

```bash
sudo rm /etc/netplan/80-wireguard-wg0.yaml /etc/netplan/81-wireguard-wg1.yaml
sudo netplan generate
sudo ip link del wg1
sudo ip link del wg0                       # networkd doesn't remove links it no longer manages
sudo systemctl enable --now wg-quick@wg0
```

Then put the router's tunnel back to its old settings: address `192.168.204.5`, endpoint port 51820, ruby's wg0 public key.

To remove wg2 or wg3, delete that YAML file on both ends, then run `netplan generate` and `ip link del wgN`.

**jennie: clients (TASKS.md phase 8).** Nothing else depends on it, so it comes out on its own:

```bash
# on jennie
sudo rm /etc/netplan/80-wireguard-wg0.yaml && sudo netplan generate && sudo ip link del wg0
sudo systemctl disable --now named         # or apt purge bind9
sudo cp -a /etc/nftables.conf.bak-YYYY-MM-DD /etc/nftables.conf && sudo systemctl reload nftables

# on ruby: remove the two 205 routes from /etc/netplan/82-wireguard-wg2.yaml, then
sudo netplan generate
sudo ip route del 192.168.205.0/24 dev wg2; sudo ip -6 route del fd33:5692:1834:205::/64 dev wg2

# on home
uci delete network.s2s_wgclient2_205; uci delete network.s2s_wgclient2_205_6
uci commit network && /etc/init.d/network reload
```

**ruby: services (Task 5e).** Put the originals back, *before* rolling wg0 back to wg-quick. Otherwise Postfix and Dovecot try to bind IPv6 addresses that no longer exist:

```bash
cd ~/wg/ruby/services
for f in $(cd orig && find etc -type f); do sudo cp "orig/$f" "/$f"; done
sudo rm /etc/systemd/system/postfix@-.service.d/local-deps.conf
sudo systemctl daemon-reload
sudo named-checkconf && sudo rndc reconfig
sudo postfix check && sudo systemctl restart postfix
sudo systemctl restart dovecot
```

**ruby: firewall.** The new rules are harmless with the old setup, so this is only needed if the firewall change itself causes trouble:

```bash
sudo cp -a /etc/nftables.conf.bak-YYYY-MM-DD /etc/nftables.conf
sudo systemctl reload nftables             # reload, NOT restart
sudo systemctl disable --now wg-docker-user.service
```

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

**Adding a client:** generate a key on the device, take the next free address (`192.168.204.6` / `fd33:5692:1834:204::6`), and add a peer to `80-wireguard-wg0.yaml` with a fresh PSK (`wg genpsk`). For a fallback tunnel too, add the same public key to `jennie/80-wireguard-wg0.yaml` with the same host number in `192.168.205.0/24` and a PSK of its own, and add its PTR to both servers' reverse zones.

**Adding a site:**

1. Use the next transit link (`172.31.1.12/30`, `fd33:5692:1834:ff04::/64`, port 51824).
2. Create a YAML file on each server end, with `routes:` for the site's networks.
3. Add the site's networks to the allowed IPs and routes of every tunnel that should reach it, and to the clients' split-tunnel list.
4. If the tunnel ends on ruby: add the interface to `WGIFS` in `/etc/nftables.conf`, add an input rule for its UDP port on `$PUB6`, and `systemctl reload nftables`. `wg-docker-user.service` matches `wg+`, so it needs no change.

***

## Found while reviewing ruby's firewall (not WireGuard)

**Port 19080 was reachable from the internet. Fixed on 2026-10-08.** The `wordpress-sogode-nginx-1` container was published on `0.0.0.0:19080` and `[::]:19080`. Docker DNATs published ports in `prerouting`, so the traffic never hit the `input` chain, and `inet filter forward` has an accept policy. The live ruleset's counters showed connections from outside reaching the container.

It's meant to be fronted by the host's nginx (`proxy_pass http://localhost:19080` in `/etc/nginx/sites-available/sogode.com`). `/opt/wordpress-sogode/docker-compose.yml` now publishes it on loopback only:

```yaml
    ports:
      - 127.0.0.1:${WEB_PORT:-80}:80
      - "[::1]:${WEB_PORT:-80}:80"
```

Both loopbacks are needed because `localhost` resolves to `::1` as well as `127.0.0.1`. The nginx container was recreated, and these checks pass:

- port 19080 listens on `127.0.0.1` and `::1` only
- `https://sogode.com/` through the host nginx returns 200
- `http://145.239.73.18:19080/` gets no response (tested from ruby itself; nothing listens on a public address any more, and Docker's DNAT rule now only matches loopback)

The compose change isn't committed; that repo already had other uncommitted edits. `nftables.conf`'s `wg0` input rule for 19080 was dead (DNAT bypasses `input`), and the draft removes it.

Also: `/etc/nginx/sites-available/sogode.com.wordpress` (not enabled) proxies to the container's bridge address (`wordpress-sogode-nginx-1.docker.local:19080`). That wouldn't work, since the container listens on port 80 inside the bridge. It's harmless while it isn't enabled.
