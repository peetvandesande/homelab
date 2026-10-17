# DNS

Distributed PowerDNS across three Debian LXC containers on `lenora`.

Local zones for the lab, plus DNS filtering: ads and malware for everyone, and
optional per-client policy sets for kids and IOT devices. One further job sits
on top, and it is a routing concern rather than a filtering one - the router's
domain-based VPN policy only works if the router resolves the names it routes
on, so Themis hands those names back to it. See invariant 11.

| CT  | Host   | IP           | Runs                | Role                              |
|-----|--------|--------------|---------------------|-----------------------------------|
| 105 | themis | 192.168.8.50 | dnsdist 1.9         | the only address clients talk to  |
| 106 | delphi | 192.168.8.51 | pdns-recursor 5.2   | recursion + RPZ filtering         |
| 107 | pythia | 192.168.8.52 | pdns-server 4.9     | authoritative for `home.` + overrides |

- **Themis** decides *who* is asking, stamps a policy tag, and hands the query
  to Delphi - except for the router's VPN policy domains, which it sends to the
  router instead. Also where Prometheus scrapes, and where DoT (:853) and DoH
  (:443) terminate.
- **Delphi** does all recursion and all filtering. It loads twelve RPZ feeds and
  applies each only to queries carrying the matching tag, so one recursor serves
  every policy set. Ads and malware apply to everyone; the rest are opt-in per
  client.
- **Pythia** holds the lab's own zones. Delphi forwards `home.` and
  `8.168.192.in-addr.arpa.` to it and never asks the internet. It also holds
  the split-horizon override for `ca.peetvandesande.com` — see invariant 5.
  The Proxmox labs' zones (`openstack.home`, `32-39.168.192.in-addr.arpa.`)
  are in a second, API-managed gsqlite3 backend that the labs write to
  themselves; their contents are deliberately not in this repo – see "Lab
  zones" in README.md.

`README.md` has the operational detail — how to add a device to a policy set,
add an internal name, what each script does, and the router-side pieces the
hourly sync needs. This file is the part you must not get
wrong.

## Working on this

**Never edit config on the hosts.** Everything under `themis/`, `delphi/` and
`pythia/` mirrors the container filesystem and is the source of truth.
`scripts/deploy.sh` pushes it and enables services; `scripts/verify.sh` is an
end-to-end smoke test that exits non-zero on failure. Run it after any change.

Secrets are in `secrets.env` (git-ignored, mode 600) and substituted into
`@@PLACEHOLDER@@` slots at push time, so no key is committed.

## Invariants — do not "simplify" these away

Each of these looks like redundancy and is not. The first four were found the
hard way; the fifth was predicted from the fourth and confirmed before it bit;
the rest came out of putting the stack behind the lab CA.

1. **Tag gating is `discardPolicy()`, not `rpzFile{tags=}`.** That option only
   labels protobuf output; it does *not* gate whether a zone matches. The
   working mechanism is `prerpz()` in `delphi/etc/powerdns/policy.lua`, and its
   polarity is inverted from how the design reads: every RPZ loads for every
   query, and the feeds outside this client's policy set are *discarded*. The
   default set is the lightest one, so a bug here under-blocks rather than
   breaking the LAN.

2. **The tag rides in a PROXY protocol TLV (type 224), not EDNS.** PROXY also
   carries the real client IP, so Delphi's logs name the device that asked.
   Consequence: Delphi's `allow_from` must be the **client** range, not
   `192.168.8.50`. Set it to the proxy and every client is refused.

3. **Themis keeps a separate packet cache per pool** — one pool per policy set
   (`""`, `"kids"`, `"iot"`). dnsdist keys its cache on the question, not the
   tag — one shared cache would serve a kids NXDOMAIN to an adult device. The
   pool split exists only for this, and a new policy set must get its own pool
   and cache or it will be served another set's verdicts.

4. **`addNTA("home.")` in `delphi/etc/powerdns/recursor.lua` is load-bearing.**
   `home.` is unsigned and does not exist at the root, so with
   `dnssec.validation=validate` the resolver proves its non-existence and every
   internal lookup SERVFAILs before Pythia's answer is considered.

5. **`ca.`, `mail.` and `ruby.peetvandesande.com` are split-horizon,
   and each needs three separate pieces to be — none of which works alone.** A zone on Pythia
   (`pythia/var/lib/powerdns/zones/ca.peetvandesande.com.zone` plus a block in
   `bindbackend.conf`), a `forward_zones` entry on Delphi, and an `addNTA()` in
   `delphi/etc/powerdns/recursor.lua`.

   The NTA is the part that looks redundant and is not. Unlike `home.`, which
   is unsigned and absent from the root, **`peetvandesande.com` is genuinely
   DNSSEC-signed** — valid DS at the parent, RRSIG over the public CNAME. So
   validation does not merely fail to find a chain: it finds a *good* chain
   proving our internal answer is a forgery, and SERVFAILs. Same symptom as
   invariant 4, opposite cause.

   **The zone is the single name, never `peetvandesande.com`.** Taking the
   parent would shadow mail, www and everything else in the domain with an
   empty internal zone and break them for the whole LAN. The NTA is scoped the
   same way, so the rest of the domain stays fully validated — check with
   `dig @192.168.8.50 peetvandesande.com A +dnssec` and look for the `ad` flag.

   Why it exists: the G3 intermediate in `homelab/ca` names
   `http://ca.peetvandesande.com/g3/` in its CRL and AIA extensions, and those
   strings are frozen into the certificate for ten years. The name had to be
   one that outlives any particular host, so internally it is pointed at
   whichever host serves the files — today pistis, 192.168.8.55.

   `mail.peetvandesande.com` is the same mechanism for a different reason:
   ruby serves IMAP only on its WireGuard address, so the public answer
   (145.239.73.18) times out from the LAN while ruby's dummy0 answers. It
   carries both of dummy0's addresses, `192.168.254.254` and
   `fd33:5692:1834:254::254`. **Every address here must reach ruby over the
   tunnel** — an AAAA that does not answer would be tried first by some
   clients and hang them, which is why there was none until 16 October 2026.
   The router's 19000 rules (11 October) are what made the v6 one answer; the
   A is reachable via `dst_net4399` as well. Nothing in `dns/` routes either.

   `ruby.peetvandesande.com` points at the same two addresses. Its nginx admits
   the admin pages (postfixadmin, rspamd, webchat) only from home and VPN
   ranges, and a LAN client that resolved the public name arrived over the
   internet from Orange's IPv6 prefix and was refused.

6. **No PowerDNS component here can serve TLS on its own webserver, so nginx
   fronts all three.** The authoritative server and the recursor have no
   certificate settings at all. dnsdist is worse than that: `setWebserverConfig`
   **accepts `certificate` and `key` without complaint and then serves plain
   HTTP**, and `--check-config` does not catch it because unknown parameters
   are silently ignored — a bogus parameter validates just as cleanly. The only
   way to know is to connect and look.

   So each backend binds loopback and nginx terminates TLS on the port the
   service always used:

   | Host | nginx (TLS) | backend (loopback) |
   |---|---|---|
   | themis | 8083 | 127.0.0.1:8383 |
   | delphi | 8082 | 127.0.0.1:8282 |
   | pythia | 8081 | 127.0.0.1:8181 |

   **Access control moved with it.** Each backend's own ACL now only ever sees
   127.0.0.1, so the `allow`/`deny` in the nginx vhost is the real one. Widening
   a backend ACL achieves nothing; narrowing it to exclude loopback breaks
   everything.

7. **dnsdist's DoH frontend advertises ALPN `h2` and nothing else.** An HTTP/1.1
   request — all the Python standard library can produce — gets a bare 400 with
   no hint why. `scripts/dns-tls-query.py` is therefore DoT-only, and verify.sh
   tests DoH with `curl --doh-url`.

8. **dnsdist reads the certificate itself and never runs as root** (`User=_dnsdist`,
   with `AmbientCapabilities=CAP_NET_BIND_SERVICE` for :443 and :853), so it must
   be in the `tlscert` group. nginx does not need this — its master process
   reads the key as root before dropping privileges.

9. **Renewal reloads dnsdist's certificates; it must not restart it.**
   `post-renew.d/30-dnsdist` calls `dnsdist -e 'reloadAllCertificates()'`, which
   swaps them in place without dropping a query. A restart would take the LAN's
   only resolver down for a certificate rotation. The restart is a fallback for
   when the console is unreachable, not the normal path.

10. **DoT and DoH bind the static address**, so the `wait-for-address` drop-in
    protects them exactly as it does `:53`. Verified across a cold boot with
    zero restarts.

11. **The router's VPN policy domains are shunted to the router, and must not
    be cached here.** The router routes by destination IP: its dnsmasq adds the
    addresses from the answers *it* returns to an ipset, and the policy matches
    on that set. Nothing else fills it, so a name under a domain policy has to
    be answered by the router or the routing silently never fires.

    Three parts, and it is broken or subtly wrong without all three:

    - **Each tunnel's own dnsmasq instance is the target**, not the main one -
      `192.168.8.1:2253` for wgclient2, `:2153` for wgclient1. Those instances
      are marked into their tunnel and resolve through it, which is what makes
      a CDN hand back edges in the right country. The main instance on `:53` is
      the fallback for when a tunnel is down; it fills the set from the same
      `via_domain` file, just with addresses from the wrong country.
    - **`setPoolServerPolicy(firstAvailable, …)`**, because dnsdist's default
      `leastOutstanding` would alternate between the tunnel resolver and the
      fallback under load, and answers would flip country query to query.
    - **No packet cache on those pools.** A router reboot flushes the ipset, and
      a cache hit here would mean nothing ever refills it. This is the one place
      in the stack where not caching is the point.

    **The shunt rule comes first in the chain and is terminal**, ahead of policy
    tagging. That is deliberate: it is what lets a kids-tagged laptop reach
    iPlayer and Bitesize through the UK tunnel while everything else it asks for
    stays filtered. Reverse the order and tagged clients lose VPN routing.

    Consequence to accept: these names bypass Delphi, so they get no RPZ and no
    DNSSEC validation. For broadcaster domains that is mostly a feature — the
    ads feed would otherwise block `bbc-reporting-api.app`, which the routing
    policy itself lists.

13. **The domain list is host state, not repo state, and a change means a
    dnsdist restart.** `vpn-domain-sync` pulls the policy from the router hourly
    and writes `/var/lib/dnsdist/vpn-domains.conf`. Four things about that are
    load-bearing:

    - **`/var/lib`, not `/etc`.** Everything under `themis/` here is pushed over
      the host's `/etc`, so a list in `/etc/dnsdist` would be reverted to
      whatever the checkout happens to hold on the next deploy. The repo does
      not carry a copy at all; the router is the only source.
    - **`dnsdist.conf` tolerates the file being absent**, because `dofile` on a
      missing file is fatal and a freshly built Themis has no list until its
      first sync. No list means no shunt, which degrades to "the tunnel is not
      used" rather than "DNS is down".
    - **A real change restarts dnsdist.** There is no live reload of the rule
      chain, and mutating a `SuffixMatchNode` a registered rule already holds
      does not reach the rule — tested on 1.9.16, the addition is invisible to
      `showRules()`. An *unchanged* list restarts nothing, which is the normal
      case, so the few seconds of dropped LAN DNS only ever follow a policy you
      edited yourself.
    - **It validates with `dnsdist --check-config` against the real config, and
      rolls back** — restoring the previous list and restarting again — if
      dnsdist will not start with the new one. Getting the LAN its resolver back
      beats installing the new list.

    **An empty render is treated as a parse failure, not an empty policy.** If
    the dump carries domains but no policy comes out of it, the sync keeps the
    last good list and exits non-zero. That gate exists because the first
    version of the script had an off-by-one in its parser, rendered nothing,
    and emptied the shunt silently — the behaviour it now refuses to repeat.
    The cost is that deliberately removing every domain on the router needs the
    list cleared by hand; that is the right way round.

    The router side is one script and one key: `/usr/local/bin/vpn-policy-dump`
    on the router, and an ed25519 key in `/etc/dnsdist/.ssh/router` on Themis
    whose `authorized_keys` entry forces that command. The key cannot get a
    shell. Both are outside this repo, which does not manage the router — a
    firmware upgrade may remove them, and the `vpn_domain_sync_success` alert is
    what tells you. `README.md` has the script to paste back.

12. **Allowlisting is `discardPolicy()`, not a passthru RPZ zone.** The obvious
    design is a small local RPZ loaded first with `CNAME rpz-passthru.` entries.
    Don't: since recursor 4.4 RPZ precedence is by *resolution stage*, not load
    order, and a passthru match in one zone is not documented to stop another
    zone applying. `allowlist.conf` is read by `policy.lua` and discards
    policies per query, which is unambiguous and is the mechanism this file
    already depends on.

    **The plain allowlist cannot punch through the malware feed**, by design;
    `allowlist-malware.conf` is the one that can, and every entry in it is a
    deliberate security decision.

Also worth knowing: recursor 5.x rejects the old `key=value` `recursor.conf`,
so settings are YAML in `recursor.yml`. `rec_control show-yaml <oldfile>`
converts one, but check its output — it collapses multi-zone `forward-zones`
into a single broken entry.

## Policy sets, and why membership is a per-device list

A policy set is a named bundle of feeds. The names appear in three places and
must agree: `POLICY_SETS` in `themis/etc/dnsdist/dnsdist.conf` (which pools to
build), `clientPolicies[…]` in `themis/etc/dnsdist/client-policies.conf` (who is
in it), and `POLICY_SETS` in `delphi/etc/powerdns/policy.lua` (which feeds it
means). A feed name must also be in `ALL_POLICIES` there, or it can never be
discarded and so applies to everyone.

| Set | Feeds |
|---|---|
| default (no tag) | ads, malware, doh |
| `kids` | + adult, gambling, nosafesearch, social, dohbypass |
| `iot` | + native_samsung, native_lgwebos, native_roku, native_tiktok |

`doh` is in the default set because a browser or app with DoH switched on
routes around this entire stack. It lists encrypted-DNS resolver names and
nothing else, so it is safe for everyone; `dohbypass` is the larger list that
also blocks VPN, Tor and proxy providers, which is why it stays kids-only.
Names are only half of it: a client that hard-codes its resolver's address never
asks Delphi, so the router rejects outgoing :53 and :853 and the well-known
resolver IPs on :443 — `router/CLAUDE.md` invariant 10. The Firefox canary
`use-application-dns.net` is answered NXDOMAIN by dnsdist on Themis, for every
client, since hagezi leaves it out of the feed.

The design says Themis tags on **source subnet**. For kids it cannot: the LAN is
flat, one `/24`, no VLANs. Membership is an explicit per-device IP list — a
deliberate decision, not an oversight. The `iot` set is written to be scoped by
subnet instead, because VLAN 10 exists for exactly that; nothing uses `tag=10`
today, and Themis has no address on that network, so enabling it also means
adding `192.168.10.0/24` to `setACL()`.

Devices need a **DHCP reservation on the router first**, or their address drifts
and they silently fall out of the policy. If kids ever get their own VLAN, swap
the per-device masks for the subnet and nothing else changes.

## Current state

Built and verified, including across cold boots. `scripts/verify.sh` passes.

**The LAN is pointed here.** `dhcp.lan.dhcp_option` on the router is
`6,192.168.8.50` plus `15,home`, so every client resolves through Themis and
is filtered. The first attempt was reverted on 9 October 2026 because it
stopped the router seeing the queries its domain-based VPN routing depends on;
invariant 11 is the fix, and the cutover was redone on 11 October 2026.

The containers stay on `192.168.8.1` via the `dnsinfra` tag — that is not a
leftover, see `router/CLAUDE.md` invariant 2.

Two things that must stay off on the router, both of which would undo this:

- **`noresolv` + `server=192.168.8.50` on the router's main dnsmasq.** Themis
  forwards the VPN domains *to* the router, so that would be a loop.
- **The force-DNS redirect** ("override DNS settings of all clients"). The
  `dns_redirect` chain is empty today; filling it would hijack clients' queries
  to `.50` back to the router.

Not yet done:

- **`client-policies.conf` is empty**, so every device gets the default set.
  Both other sets are proven working — tested end to end with a temporary entry,
  including cache isolation and the shunt still winning for a tagged client.
- **DoH is not reachable from outside.** It works on the LAN (`:443`), but
  there is no port forward, so it is internal-only for now.
- **Alerts notify nowhere.** The `dns` rule group in `grafana/` evaluates and
  shows in the UI, but no contact point is configured yet.
