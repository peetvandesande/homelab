# DNS

Three containers on `lenora`, in the Infrastructure pool.

| CT  | Host   | IP           | Runs                | Role                                   |
|-----|--------|--------------|---------------------|----------------------------------------|
| 105 | themis | 192.168.1.50 | dnsdist 1.9         | the only address clients talk to       |
| 106 | delphi | 192.168.1.51 | pdns-recursor 5.2   | recursion + RPZ filtering              |
| 107 | pythia | 192.168.1.52 | pdns-server 4.9     | authoritative for `home.`              |

All three are Debian 13, unprivileged, `onboot=1`, IPv4 static + IPv6 SLAAC,
root login by key only.

## How a query flows

```
client ──▶ themis ──▶ delphi ──▶ internet
           (tag)      (filter)      │
                          └──▶ pythia   (home., 1.168.192.in-addr.arpa.,
                                         and ca.peetvandesande.com.)
```

Themis decides *who* is asking and stamps a policy tag. Delphi decides *what*
they may have. Pythia answers for the lab's own names, plus the handful of
public names deliberately overridden internally.

### The tag

Themis matches the client against `kidsDevices` and, on a hit, attaches a
PROXY protocol TLV (type 224, value `kids`) before forwarding. Delphi's
`policy.lua` reads that TLV in `prerpz()` and, when it is *absent*, calls
`discardPolicy()` on the adult and social feeds — so the default is the
lighter policy and the kids policy is opt-in per device.

Two things worth knowing about this:

- **PROXY protocol, not EDNS**, because it also carries the real client IP.
  Delphi's logs and `rec_control top-remotes` name the device that asked, not
  Themis. `allow_from` on Delphi is therefore the *client* range, not
  `192.168.1.50`.
- **`rpzFile()`'s `tags` option does not do this.** It only labels protobuf
  output; it does not gate whether a zone matches. `discardPolicy()` in
  `prerpz` is the supported mechanism, so don't "simplify" policy.lua away.

### Cache separation

Themis keeps a **separate packet cache per pool** (`""` and `"kids"`). This is
not an optimisation — dnsdist keys its cache on the question, not on the tag,
so a single shared cache would serve a kids NXDOMAIN to an adult device and
vice versa. Verified: with the same name queried from both a tagged and an
untagged client seconds apart, each gets its own verdict.

## Filtering

Feeds are listed in `delphi/etc/powerdns/rpz-feeds.conf` and land in
`/var/lib/powerdns/rpz/`:

| Feed      | Source (hagezi)  | Applies to |
|-----------|------------------|------------|
| `malware` | `tif.medium.txt` | everyone   |
| `adult`   | `nsfw.txt`       | kids only  |
| `social`  | `social.txt`     | kids only  |

`rpz-update.timer` refreshes them daily (randomised up to 2h, `Persistent=true`)
and then runs `rec_control reload-lua-config` — `rpzFile()` reads from disk
once at load and does not poll.

The updater refuses to install a feed that fails to download, has no SOA, or
falls under the line-count tripwire in the config. A stale feed beats an empty
one silently unblocking everything.

The commented block in `rpz-feeds.conf` has IOT-telemetry and ad feeds ready to
enable. They're off because they need a matching `rpzFile()` block in
`recursor.lua`, and because which vendor lists you want depends on what's
actually on the network.

## Adding a kids device

The LAN is flat — one `/24`, no VLANs — so there is no kids subnet to match on
and membership is an explicit list.

1. Give the device a **DHCP reservation** on the router first, or its address
   will drift and it will silently fall out of the policy.
2. Add a line to `themis/etc/dnsdist/kids-devices.conf`.
3. `./scripts/deploy.sh`
4. From that device: `dig @192.168.1.50 bsky.app` should be `NXDOMAIN`.

If you ever put kids on their own VLAN, replace the per-device masks with the
subnet and nothing else changes.

## Adding an internal name

Edit `pythia/var/lib/powerdns/zones/home.zone` (and the reverse zone), **bump
the serial in both**, then `./scripts/deploy.sh`.

`home.` is unsigned and does not exist at the root, so Delphi carries an
`addNTA("home.")` in `recursor.lua`. Without it, DNSSEC validation proves the
zone's non-existence and every internal lookup SERVFAILs before Pythia's
answer is even considered.

## Overriding a public name internally (split-horizon)

`ca.peetvandesande.com` is the worked example: publicly a CNAME to an OVH VPS,
internally an A record for pistis (192.168.1.55), because that is where the
CA's CRL and AIA files live. See `homelab/ca`.

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
dig @192.168.1.50 <parent-domain> A +dnssec | grep flags:
```

## Encrypted DNS

Themis serves DoT and DoH off the lab CA, in addition to plain Do53:

| Transport | Address | Notes |
|---|---|---|
| Do53 | `192.168.1.50:53` | unchanged |
| DoT | `192.168.1.50:853` | |
| DoH | `https://192.168.1.50/dns-query` | **HTTP/2 only** |

Queries over all three go through the same rule chain, so kids tagging and the
cache pool split apply identically. There is no separate path for encrypted
clients and there must not be one.

Clients need to trust the G2 root, and — until the DHCP cutover — must address
Themis **by IP**, because nothing resolves `themis.home` yet. Every lab
certificate carries an IP SAN for exactly this.

Testing by hand:

```sh
# DoT. macOS dig is 9.10 and has no +tls, hence the helper.
./scripts/dns-tls-query.py dot 192.168.1.50 853 grafana.home ../ca/rootca/certs/root.crt

# DoH. Must be an HTTP/2 client - dnsdist advertises ALPN h2 only, and an
# HTTP/1.1 request comes back as a bare 400.
curl --cacert ../ca/rootca/certs/root.crt \
     --doh-url https://192.168.1.50/dns-query https://grafana.home:3000/api/health
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

Prometheus (192.168.1.53) scrapes all three under `job="dns"`, plus
node_exporter on each under `job="node"`. All three `/metrics` endpoints are
unauthenticated but ACL'd to the Prometheus container.

The pre-change `prometheus.yml` is kept as `prometheus.yml.pre-dns.bak` on
that host. Note that its `node` job had been scraping `.50`/`.51` labelled
`jellyfin`/`navidrome` long after those services moved to `.60`/`.61`; those
labels now describe this stack, and the two service jobs were repointed.

## Still to do

- **Point clients at Themis.** Nothing uses it yet: hand out `192.168.1.50` as
  the only DNS server via DHCP on the router. The containers themselves stay
  on `192.168.1.1` deliberately — Delphi is Themis's backend, and pointing it
  at Themis would be a resolution loop at boot.
- **Populate `kids-devices.conf`.** It is empty, so every device currently gets
  the malware feed only.
- **Grafana dashboards and alerts** off the `dns` job.
- **DoH on Themis** if you want phones filtered off-LAN. Deliberately not
  enabled; it needs a certificate and a port forward.

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
