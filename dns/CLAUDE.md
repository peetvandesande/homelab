# DNS

Distributed PowerDNS across three Debian LXC containers on `lenora`.

The intent is local zones for the lab plus DNS filtering for IOT, kids and
malware protection.

| CT  | Host   | IP           | Runs                | Role                              |
|-----|--------|--------------|---------------------|-----------------------------------|
| 105 | themis | 192.168.1.50 | dnsdist 1.9         | the only address clients talk to  |
| 106 | delphi | 192.168.1.51 | pdns-recursor 5.2   | recursion + RPZ filtering         |
| 107 | pythia | 192.168.1.52 | pdns-server 4.9     | authoritative for `home.` + overrides |

- **Themis** decides *who* is asking, stamps a policy tag, and hands the query
  to Delphi. Also where Prometheus scrapes, and where DoT (:853) and DoH
  (:443) terminate.
- **Delphi** does all recursion and all filtering. It loads several RPZ feeds
  and applies each only to queries carrying the matching tag, so one recursor
  gives two policies. Malware applies to everyone; adult-content and
  social-media only to kids.
- **Pythia** holds the lab's own zones. Delphi forwards `home.` and
  `1.168.192.in-addr.arpa.` to it and never asks the internet. It also holds
  the split-horizon override for `ca.peetvandesande.com` — see invariant 5.

`README.md` has the operational detail — how to add a kids device, add an
internal name, what each script does. This file is the part you must not get
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
   query, and the kids-only feeds are *discarded* when the tag is absent.

2. **The tag rides in a PROXY protocol TLV (type 224), not EDNS.** PROXY also
   carries the real client IP, so Delphi's logs name the device that asked.
   Consequence: Delphi's `allow_from` must be the **client** range, not
   `192.168.1.50`. Set it to the proxy and every client is refused.

3. **Themis keeps a separate packet cache per pool** (`""` and `"kids"`).
   dnsdist keys its cache on the question, not the tag — one shared cache
   would serve a kids NXDOMAIN to an adult device. The pool split exists only
   for this.

4. **`addNTA("home.")` in `delphi/etc/powerdns/recursor.lua` is load-bearing.**
   `home.` is unsigned and does not exist at the root, so with
   `dnssec.validation=validate` the resolver proves its non-existence and every
   internal lookup SERVFAILs before Pythia's answer is considered.

5. **`ca.peetvandesande.com` is split-horizon, and needs three separate pieces
   to be — none of which works alone.** A zone on Pythia
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
   `dig @192.168.1.50 peetvandesande.com A +dnssec` and look for the `ad` flag.

   Why it exists: the G3 intermediate in `homelab/ca` names
   `http://ca.peetvandesande.com/g3/` in its CRL and AIA extensions, and those
   strings are frozen into the certificate for ten years. The name had to be
   one that outlives any particular host, so internally it is pointed at
   whichever host serves the files — today pistis, 192.168.1.55.

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

Also worth knowing: recursor 5.x rejects the old `key=value` `recursor.conf`,
so settings are YAML in `recursor.yml`. `rec_control show-yaml <oldfile>`
converts one, but check its output — it collapses multi-zone `forward-zones`
into a single broken entry.

## Kids membership is a per-device list

The design says Themis tags on **source subnet**. It cannot: the LAN is flat,
one `/24`, no VLANs. Membership is an explicit per-device IP list in
`themis/etc/dnsdist/kids-devices.conf` — a deliberate decision, not an
oversight.

Devices need a **DHCP reservation on the router first**, or their address
drifts and they silently fall out of the policy. If kids ever get their own
VLAN, swap the per-device masks for the subnet and nothing else changes.

## Current state

Built and verified, including across cold boots. Not yet done:

- **`kids-devices.conf` is empty**, so every device currently gets the malware
  feed only. The kids path itself is proven working — it was tested end to end
  with a temporary entry, including cache isolation between the two policies.
- **No client cutover.** Nothing uses Themis yet; the router still hands out
  192.168.1.1. The three containers must stay on 192.168.1.1 regardless —
  pointing Delphi at Themis is a boot-time resolution loop.

  This now costs something concrete: the `ca.peetvandesande.com` split-horizon
  (invariant 5) is live and correct at Themis, but **no host on the LAN sees
  it** — they all still resolve that name to the public VPS and get a 404 for
  the CA's CRL and AIA. The CA cannot do revocation checking until the cutover
  happens.
- **IOT filtering is not enabled.** Feeds are staged and commented in
  `delphi/etc/powerdns/rpz-feeds.conf`; enabling one also needs a matching
  `rpzFile()` block in `recursor.lua`. Which vendor lists are wanted depends on
  what is actually on the network.
- **DoH is not reachable from outside.** It works on the LAN (`:443`), but
  there is no port forward, so it is internal-only for now.
- **No Grafana dashboards or alerts** off the `dns` job.
