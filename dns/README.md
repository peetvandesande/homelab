# DNS

Three containers on `lenora`, in the Infrastructure pool.

| CT  | Host   | IP           | Runs                | Role                                   |
|-----|--------|--------------|---------------------|----------------------------------------|
| 105 | themis | 192.168.8.50 | dnsdist 1.9         | the only address clients talk to       |
| 106 | delphi | 192.168.8.51 | pdns-recursor 5.2   | recursion + RPZ filtering              |
| 107 | pythia | 192.168.8.52 | pdns-server 4.9     | authoritative for `home.`              |

All three are Debian 13, unprivileged, `onboot=1`, IPv4 by DHCP reservation +
IPv6 SLAAC, root login by key only.

## How a query flows

```
client ──▶ themis ──▶ delphi ──▶ internet
           (tag)   │  (filter)      │
                   │      └──▶ pythia   (home., 8.168.192.in-addr.arpa.,
                   │                      ca. and mail.peetvandesande.com.)
                   └──▶ router :2253 ──▶ wgclient2 tunnel
                        (VPN policy domains - fills the routing ipset)
```

Themis decides *who* is asking and stamps a policy tag. Delphi decides *what*
they may have. Pythia answers for the lab's own names, plus the handful of
public names deliberately overridden internally. The one set of names Themis
answers differently is the router's VPN policy domains — see below.

### The policy sets

| Set | Feeds | Who |
|---|---|---|
| default | ads, malware, doh | everything with no tag |
| `kids` | + adult, gambling, nosafesearch, social, dohbypass | listed devices |
| `iot` | + native_samsung, native_lgwebos, native_roku, native_tiktok | listed subnets |

### The tag

Themis matches the client against each `clientPolicies[<set>]` netmask group
and, on a hit, attaches a PROXY protocol TLV (type 224) carrying the set name
before forwarding. Delphi's `policy.lua` reads that TLV in `prerpz()` and calls
`discardPolicy()` on every feed outside that set — so the default is the
lightest policy and everything else is opt-in per device.

Two things worth knowing about this:

- **PROXY protocol, not EDNS**, because it also carries the real client IP.
  Delphi's logs and `rec_control top-remotes` name the device that asked, not
  Themis. `allow_from` on Delphi is therefore the *client* range, not
  `192.168.8.50`.
- **`rpzFile()`'s `tags` option does not do this.** It only labels protobuf
  output; it does not gate whether a zone matches. `discardPolicy()` in
  `prerpz` is the supported mechanism, so don't "simplify" policy.lua away.

### Cache separation

Themis keeps a **separate packet cache per pool**, one pool per policy set. This
is not an optimisation — dnsdist keys its cache on the question, not on the tag,
so a single shared cache would serve a kids NXDOMAIN to an adult device and
vice versa. Verified: with the same name queried from both a tagged and an
untagged client seconds apart, each gets its own verdict.

A new policy set needs its own pool and cache, which is why `POLICY_SETS` in
`dnsdist.conf` drives both.

## Filtering

Feeds are listed in `delphi/etc/powerdns/rpz-feeds.conf` and land in
`/var/lib/powerdns/rpz/<name>.rpz`. The name is the join between three files:
the feed list, the `FEEDS` table in `recursor.lua`, and `ALL_POLICIES` plus
`POLICY_SETS` in `policy.lua`. Miss it out of `ALL_POLICIES` and the feed can
never be discarded, so it silently applies to everyone.

All twelve come from [hagezi](https://github.com/hagezi/dns-blocklists):

| Feed | Source | Lines | Set |
|---|---|---|---|
| `ads` | `pro.txt` | 387k | default |
| `malware` | `tif.medium.txt` | 1.27M | default |
| `doh` | `doh.txt` | 6.6k | default |
| `adult` | `nsfw.txt` | 180k | kids |
| `gambling` | `gambling.medium.txt` | 414k | kids |
| `nosafesearch` | `nosafesearch.txt` | 422 | kids |
| `social` | `social.txt` | 1.8k | kids |
| `dohbypass` | `doh-vpn-proxy-bypass.txt` | 32k | kids |
| `native_samsung` | `native.samsung.txt` | 416 | iot |
| `native_lgwebos` | `native.lgwebos.txt` | 476 | iot |
| `native_roku` | `native.roku.txt` | 162 | iot |
| `native_tiktok` | `native.tiktok.txt` | 910 | iot |

That is ~2.3M entries; Delphi has 6GB for it. `native.apple` and
`native.amazon` are deliberately left out — they break device setup, Alexa and
Prime Video rather than just telemetry.

`rpz-update.timer` refreshes them daily (randomised up to 2h, `Persistent=true`)
and then runs `rec_control reload-lua-config` — `rpzFile()` reads from disk
once at load and does not poll.

The updater refuses to install a feed that fails to download, has no SOA, or
falls under the line-count tripwire in the config. A stale feed beats an empty
one silently unblocking everything. A feed that has *never* downloaded has
nothing to fall back on and `rpzFile()` on a missing file is a fatal startup
error, so `deploy.sh` asserts every declared feed is present before it restarts
the recursor.

Every hagezi list ships a canary domain named after the list file —
`h4g3z1-pro.web.app`, `h4g3z1-nsfw.web.app` and so on. `verify.sh` derives them
from the URLs in `rpz-feeds.conf` and tests each feed exactly, which is why
adding a feed needs no change to the test.

## Allowlisting

Two files on Delphi, both plain lists of domains, one per line; an entry covers
the name and everything under it.

| File | Overrides |
|---|---|
| `allowlist.conf` | every feed **except** malware |
| `allowlist-malware.conf` | every feed, malware included |

Both apply to all clients, tagged ones included. There is no per-set allowlist.

It is done in `policy.lua` rather than as a passthru RPZ zone on purpose: RPZ
precedence across zones is by resolution stage, not load order, since recursor
4.4, so a passthru in one zone is not dependably the last word.

## The router's VPN policy domains

The router sends traffic into a WireGuard tunnel by **destination IP**: its
dnsmasq adds the addresses from the answers it returns to an ipset
(`/var/run/dnsmasq/via_domain` → `ipset=/bbc.co.uk/dst_net6611`), and the policy
matches on that set. Nothing else fills it. So if Themis answers those names,
the routing never fires.

Themis therefore shunts them straight to the **tunnel's own dnsmasq instance**
(`192.168.8.1:2253` for wgclient2), which is marked into that tunnel and
resolves through it — so Fastly and Akamai hand back UK edges, and dnsmasq fills
the set as it answers. The router's main instance on `:53` is the fallback for
when the tunnel is down.

The rule is first in the chain and terminal, so **a kids-tagged device still
gets it**: the laptop reaches iPlayer and Bitesize through the UK tunnel while
everything else it asks for stays filtered. That is the whole reason the shunt
exists rather than a device-based VPN rule.

These names bypass Delphi entirely — no RPZ, no DNSSEC validation. For
broadcaster domains that is mostly a feature; the ads feed would otherwise block
`bbc-reporting-api.app`, which the routing policy itself lists.

### The router owns the list, and Themis syncs it hourly

`/etc/domain_mac_list/<set>` on the router is the source of truth — the GL.iNet
web UI writes it, so this repo carries no copy of it at all. Edit the policy in
the UI and within the hour Themis follows; there is nothing to regenerate and
nothing to commit.

`vpn-domain-sync.timer` on Themis runs `/usr/local/bin/vpn-domain-sync` hourly
(jittered 5m, `Persistent=true`). It pulls the policy, renders
`/var/lib/dnsdist/vpn-domains.conf`, and **only** restarts dnsdist if the list
actually changed — an unchanged list does nothing at all, which is the normal
case. dnsdist has no live reload of its rule chain, so a genuine change costs a
few seconds of LAN DNS; that follows a policy you edited, not a schedule.

To apply a change immediately rather than waiting:

```sh
ssh root@192.168.8.50 vpn-domain-sync
```

The file is under `/var/lib` on purpose: everything in `themis/` here is pushed
over the host's `/etc`, so a list there would be reverted to the checkout's copy
on the next deploy.

**Failure is designed to be quiet but visible.** A router it cannot reach, a
truncated dump, a list that renders no policies, or a config dnsdist refuses all
leave the previous list in place and exit non-zero. If there is no list at all —
a freshly built Themis before its first sync — dnsdist starts without the shunt,
so the policy domains resolve normally and the tunnel simply isn't used.

Nothing about that is obvious from the outside, so it is monitored:

| Metric | Means |
|---|---|
| `vpn_domain_sync_success` | 0 after a failed sync |
| `vpn_domain_sync_last_success_seconds` | staleness — the timer stopped |
| `vpn_domain_sync_domains{pool=…}` | 0 means the tunnel will never be used |
| `vpn_domain_sync_changed` | 1 on the run that installed a change |

They reach Prometheus through node-exporter's textfile collector (see
`node-exporter/CLAUDE.md`), appear on the **DNS stack** dashboard
(`/d/homelab-dns`) and are alerted on by the `dns` rule group in `grafana/`.
`rpz-update` publishes feed freshness the same way (`rpz_feed_*`).

### The two pieces that live on the router

The sync needs a read-only dump command on the router and an `authorized_keys`
entry that forces Themis's key to it. Neither is in this repo — the router is
documented, not managed, in `router/` — and a firmware upgrade can remove both.
The `vpn_domain_sync_success` alert is what tells you, and
**`router/README.md` has both to paste back**.

`deploy.sh` mints the key if it is missing and prints exactly what to authorise,
so a rebuilt Themis needs only that paste.

Two traps the sync handles that a hand-written version gets wrong:

- The lists carry bare destination IPs and prefixes alongside the domains. Those
  are set members the router adds directly and have no DNS dimension —
  `dst_net4399` is *entirely* those, a site-to-site policy, and produces no
  dnsmasq lines at all. Filtering them by "looks like hex and dots" would also
  eat real domains like `face.be`, so the test is for `:`, `/` or a strict
  dotted quad.
- **The router's files have no trailing newline**, so a `while read` loop drops
  the last entry. It uses `awk`.

The set→resolver mapping is derived, not hardcoded: the rule's `via` names the
tunnel and `dhcp.<tunnel>.port` gives its dnsmasq instance. Add a domain to the
Main VPN policy and a second pool on `:2153` appears by itself.

## Adding a device to a policy set

The LAN is flat — one `/24`, no VLANs — so there is no kids subnet to match on
and membership is an explicit list.

1. Give the device a **DHCP reservation** on the router first, or its address
   will drift and it will silently fall out of the policy.
2. Add a line to `themis/etc/dnsdist/client-policies.conf`.
3. `./scripts/deploy.sh`
4. From that device: `dig @192.168.8.50 h4g3z1-social.web.app` should be
   `NXDOMAIN`, and `dig @192.168.8.50 bbc.co.uk` should still answer.

If you ever put kids on their own VLAN, replace the per-device masks with the
subnet and nothing else changes.

## Adding an internal name

Edit `pythia/var/lib/powerdns/zones/home.zone` (and the reverse zone), **bump
the serial in both**, then `./scripts/deploy.sh`.

`home.` is unsigned and does not exist at the root, so Delphi carries an
`addNTA("home.")` in `recursor.lua`. Without it, DNSSEC validation proves the
zone's non-existence and every internal lookup SERVFAILs before Pythia's
answer is even considered.

## Lab zones (API-managed)

The Proxmox labs (`openstack-lab`, `nutanix-lab`) share `192.168.32.0/21`,
which the router routes to lenora. Only one lab runs at a time. A lab
registers its own names: its bootstrap playbook creates a zone such as
`openstack.home` and the reverse zones for its subnets through Pythia's API,
and its teardown deletes them.

These zones live in a second backend on Pythia, **gsqlite3**
(`/var/lib/powerdns/labs.sqlite3`), not in this repo. They change every time
a lab is built or removed, and the bind backend can't be written through the
API. Pythia answers from whichever backend has the most specific zone, so
`openstack.home` works inside `home.` without a delegation.

The fixed pieces are in this repo:

- `pdns.conf` launches `gsqlite3,bind`. gsqlite3 comes first, so zones created
  through the API land there.
- nginx on Pythia allows lenora (`192.168.8.21`) to reach `/api/` on `:8081`.
  The labs call the API from lenora, which has a static address and trusts
  the lab CA. The API key is `AUTH_API_KEY` in `secrets.env`.
- Delphi forwards `32-39.168.192.in-addr.arpa.` to Pythia and has an NTA for
  each one. The forward zones need nothing extra, because `home.` already
  covers them.
- Themis and Delphi accept queries from `192.168.32.0/21`, so lab nodes and
  instances can use `192.168.8.50` as their resolver.

`deploy.sh` installs `pdns-backend-sqlite3` and creates the database the
first time. After that it never touches the database's contents. To see
what a lab has registered:

```sh
ssh root@192.168.8.52 pdnsutil list-all-zones
ssh root@192.168.8.52 pdnsutil list-zone openstack.home
```

While no lab is running, reverse lookups in `192.168.32.0/21` return
SERVFAIL, because Delphi forwards them to a zone that doesn't exist. That is
expected.

## Overriding a public name internally (split-horizon)

`ca.peetvandesande.com` is the worked example: publicly a CNAME to an OVH VPS,
internally an A record for pistis (192.168.8.55), because that is where the
CA's CRL and AIA files live. See `homelab/ca`.

`mail.peetvandesande.com` is the second one, and overridden for a different
reason: ruby, the mail server, serves IMAP only on its WireGuard address.
Internally the name is ruby's dummy0: A `192.168.254.254` and AAAA
`fd33:5692:1834:254::254`, both routed into wgclient1 by the router's
site-to-site rules — see `router/README.md`. The AAAA arrived on 16 October
2026; before the router's 19000 rules, the v6 address did not answer from the
LAN, and an AAAA that does not answer hangs any client that tries it first.

`ruby.peetvandesande.com` is the third, pointing at the same two addresses:
ruby's nginx admits its admin pages only from home and VPN ranges, and a LAN
client resolving the public name arrives over the internet from its ISP IPv6
address.

It takes **three** changes, and it is broken until all three are in place:

1. A zone file in `pythia/var/lib/powerdns/zones/` and a matching block in
   `pythia/etc/powerdns/bindbackend.conf`.
2. A `forward_zones` entry on Delphi in `recursor.yml`, `recurse: false`.
3. An `addNTA()` in `delphi/etc/powerdns/recursor.lua`.

Then `./scripts/deploy.sh`.

**Make the zone the exact name you are overriding, never its parent.** A zone
for `peetvandesande.com` would shadow mail, www and everything else in the
domain with an empty internal zone, for the whole LAN.

Step 3 is the one people skip. A signed parent domain makes it mandatory:
validation finds a good chain proving the internal answer is a forgery and
returns SERVFAIL — not the "no chain found" failure `home.` produces. Check
whether you need it with:

```sh
dig +short @1.1.1.1 <parent-domain> DS      # non-empty means signed
```

Afterwards, confirm you scoped it tightly — the parent should still come back
with the `ad` flag set:

```sh
dig @192.168.8.50 <parent-domain> A +dnssec | grep flags:
```

## Encrypted DNS

Themis serves DoT and DoH off the lab CA, in addition to plain Do53:

| Transport | Address | Notes |
|---|---|---|
| Do53 | `192.168.8.50:53` | unchanged |
| DoT | `192.168.8.50:853` | |
| DoH | `https://192.168.8.50/dns-query` | **HTTP/2 only** |

Queries over all three go through the same rule chain, so kids tagging and the
cache pool split apply identically. There is no separate path for encrypted
clients and there must not be one.

Clients need to trust the G2 root. Addressing Themis **by IP** always works,
because every lab certificate carries an IP SAN; since the DHCP cutover a
client that already uses Themis can resolve `themis.home` and verify the name
instead. A client being configured for the first time has no resolver yet, so
the IP remains the sensible thing to type.

Testing by hand:

```sh
# DoT. macOS dig is 9.10 and has no +tls, hence the helper.
./scripts/dns-tls-query.py dot 192.168.8.50 853 grafana.home ../ca/rootca/certs/root.crt

# DoH. Must be an HTTP/2 client - dnsdist advertises ALPN h2 only, and an
# HTTP/1.1 request comes back as a bare 400.
curl --cacert ../ca/rootca/certs/root.crt \
     --doh-url https://192.168.8.50/dns-query https://grafana.home:3000/api/health
```

## Metrics endpoints are behind nginx

None of the three components can serve TLS itself, so each backend binds
loopback and nginx terminates TLS on the port it always used — 8083 (themis),
8082 (delphi), 8081 (pythia). Target addresses did not change.

**nginx allows only Prometheus (.53).** From anywhere else these return 403,
which still proves TLS terminated and the chain verified. Do not "fix" a 403 by
widening the backend ACL — the backend only ever sees 127.0.0.1 now, and the
real access control is the `allow`/`deny` in the vhost.

## Scripts

| Script                | Runs on      | Does                                       |
|-----------------------|--------------|--------------------------------------------|
| `scripts/bootstrap.sh`| Proxmox host | creates the three CTs; skips existing ones |
| `scripts/deploy.sh`   | workstation  | pushes config, validates, enables services |
| `scripts/verify.sh`   | workstation  | end-to-end smoke test; exits non-zero on failure |
| `vpn-domain-sync`     | themis (hourly) | pulls the VPN domain policy from the router |

`deploy.sh` copies files one at a time and writes them atomically as
`root:root`. It does **not** stream a tarball into `/` — tar carries the
workstation's uid/gid and mode on the archive's own top-level entry, which
rewrites `/` itself to `0700` owned by uid 501 and breaks every service on the
box.

Secrets live in `secrets.env` (git-ignored, mode 600). `deploy.sh` substitutes
them into the `@@PLACEHOLDER@@` slots at push time, so no key is stored in the
config files here. dnsdist wants a scrypt hash rather than a plaintext key;
that is minted once on first deploy and cached back into `secrets.env`, because
`hashPassword()` salts randomly and recomputing it would bounce the service on
every run.

## Monitoring

Prometheus (192.168.8.53) scrapes all three under `job="dns"`, plus
node_exporter on each under `job="node"`. All three `/metrics` endpoints are
unauthenticated but ACL'd to the Prometheus container.

The pre-change `prometheus.yml` is kept as `prometheus.yml.pre-dns.bak` on
that host. Note that its `node` job had been scraping `.50`/`.51` labelled
`jellyfin`/`navidrome` long after those services moved to `.60`/`.61`; those
labels now describe this stack, and the two service jobs were repointed.

## Still to do

- ~~**Point clients at Themis.**~~ Done on 11 October 2026:
  `dhcp.lan.dhcp_option` is `6,192.168.8.50` with `15,home`. An earlier attempt
  was reverted on 9 October because it stopped the router's domain-based VPN
  routing working; the shunt above is what made it stick.

  The containers themselves stay on `192.168.8.1` deliberately (the `dnsinfra`
  tag) — Delphi is Themis's backend, and pointing it at Themis would be a
  resolution loop at boot.

  Two things must stay off on the router, both of which would undo the shunt:
  `noresolv` + `server=192.168.8.50` on its main dnsmasq (Themis forwards *to*
  the router, so that is a loop), and the force-DNS redirect, which would hijack
  clients' queries to `.50` straight back to the router.
- **Populate `client-policies.conf`.** It is empty, so every device gets the
  default set.
- **Somewhere for alerts to go.** The `dns` rule group in `grafana/` covers the
  stack — components down, the shunt empty, the sync failing or stale, feeds
  stale, SERVFAIL rate, clients being rate-limited — and the **DNS stack**
  dashboard (`/d/homelab-dns`) shows it. But no contact point is configured, so
  they are visible in the Grafana UI and delivered nowhere.
- **DoH from outside** if you want phones filtered off-LAN. It works on the LAN
  already; it needs a port forward.

## Gotchas

- **Each service waits for its own IP before starting**, via a
  `wait-for-address.conf` systemd drop-in. In an LXC with ifupdown,
  `network-online.target` is reached before `eth0` has an address; on a cold
  boot Themis bound port 53 but its webserver got "Cannot assign requested
  address" and stayed down. The drop-in's `ExecStartPre` needs the leading `+`
  to run outside the unit sandbox — these units set `RestrictAddressFamilies`,
  which blocks the netlink socket `ip` uses.
- A `systemctl restart` of pdns can report failure while the outgoing process
  still holds its control socket. `Restart=on-failure` recovers within a
  second, so `deploy.sh` asserts the end state rather than trusting the
  restart's exit code.
- After `systemctl restart dnsdist`, Themis drops queries for up to ~5s until
  the backend's first health check passes. Harmless, but don't panic-debug an
  empty `dig` immediately after a deploy.
- Recursor 5.x rejects the old `key=value` `recursor.conf`; settings are YAML
  in `recursor.yml`. `rec_control show-yaml <oldfile>` converts one — but
  check its output, it mis-parses multi-zone `forward-zones` into a single
  entry.
- `pdns_server --config=check` validates the auth config; there is no
  `--check-config` on 4.9.
