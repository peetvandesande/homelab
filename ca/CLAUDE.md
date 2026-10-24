# CA

Smallstep three-tier Private Certificate Authority on Debian LXC container on `lenora`.

The intent is to use privately signed certificates across all services in homelab.

| CT  | Host   | IP           | Runs                | Role                              |
|-----|--------|--------------|---------------------|-----------------------------------|
| 101 | pistis | 192.168.8.55 | step-ca 0.30.2      | CA                                |

- **Pistis** holds the G3 intermediate and acts as the issuing CA — signing and
  revoking leaf certificates, over ACME and by hand.

The three tiers are **root → intermediate → leaf**:

```
Peet van de Sande Root Certificate G2      rootca/ — offline, on the workstation
  C=GB, ST=England, L=London               RSA-4096, expires Dec 2046
        │
        ▼
Peet van de Sande Intermediate CA G3       pistis, step-ca
  C=FR, ST=Bouches-du-Rhone                ECDSA P-256, pathlen:0
        │
        ▼
leaf certificates                          ACME (auto) or JWK (by hand)
```

`README.md` has the operational detail — how to get a certificate, how to
revoke one, what is not done yet. This file is the part you must not get wrong.

## Working on this

**Never edit config on the hosts.** Everything under `pistis/` mirrors the container
filesystem and is the source of truth.
`scripts/deploy.sh` pushes it and enables services; `scripts/verify.sh` is an
end-to-end smoke test that exits non-zero on failure. Run it after any change.

Secrets are in `secrets.env` (git-ignored, mode 600) and substituted into
`@@PLACEHOLDER@@` slots at push time, so no key is committed.

The existing root CA files are in `rootca/`.

## Invariants — do not "simplify" these away

1. **The root key stays out of this repo and off every host, and only two
   scripts ever touch it.** `scripts/make-intermediate.sh` and
   `scripts/root-crl.sh`, both prompting interactively. It is not in
   `secrets.env` and must not be added — `secrets.env` holds
   `STEP_CA_KEY_PASSWORD`, `STEP_CA_JWK_PASSWORD` and `JWK_PROVISIONER`, all
   of which are G3-level and below. Pistis holds the G3 key and nothing above
   it.

   **The root key and both passphrases are in a password manager**, by choice,
   so a dead workstation does not end the hierarchy's ability to mint a new
   intermediate or regenerate the root CRL. This file used to say the root key
   never left the workstation and its passphrase was never written down; that
   described an earlier, more brittle arrangement, not this one.

   The consequence to hold in mind: the keys and the passphrases that protect
   them are in the same vault, so against a compromise of that vault the
   encryption buys nothing, and that vault is now the root of trust for every
   certificate in the lab. That is the trade made for recoverability. It is
   also why the rule above still stands — a second copy of a passphrase in
   `secrets.env`, which sits in a working tree next to a public repo, would add
   exposure without adding any recoverability the vault does not already give.

2. **`rootca/openssl.cnf` is a historical record, not live configuration.** Its
   `dir` still points at `/home/peet/ca.g2/root`, which exists nowhere. The
   scripts rewrite that line into a throwaway copy. Do not "fix" the original —
   and do not add a G3 section to it. The G3 extensions live in
   `intermediate/g3-ext.cnf` and are passed with `-extfile`.

3. **G3 is signed with `-policy policy_loose`.** The root's default
   `policy_strict` requires `countryName` and `stateOrProvinceName` to *match*
   the root's own GB/England. G3 is deliberately FR/Bouches-du-Rhone, so strict
   matching refuses it outright. Loosening the policy at the command line
   changes nothing about what the certificate can do.

4. **`authority.enableAdmin` in `ca.json` is `false`.** Set it true and
   provisioners migrate into the badger DB, `step ca provisioner add` becomes
   the only way to change them, and the file in this repo silently stops being
   the truth.

5. **The JWK provisioner is minted exactly once**, on first deploy, and stored
   in `secrets.env` as `JWK_PROVISIONER`. `--create` mints a fresh key every
   time it is called; re-minting changes the `kid` and breaks every client that
   has bootstrapped against it.

6. **The root CRL must be current before anything trusts G3.** The G3
   certificate names `http://ca.peetvandesande.com/g3/root.crl` in its
   `crlDistributionPoints`, and a CDP pointing at an expired CRL is worse than
   no CDP — clients that honour it reject the whole chain, silently, on the day
   it lapses. The CRL in this repo had been expired since January 2017.
   `deploy.sh` refuses to publish an expired one.

7. **The URLs in the certificate name a domain, never a host.** They are frozen
   for G3's full ten years and cannot be changed without reissuing it and every
   leaf under it, so they must outlive pistis, step-ca, and any other
   implementation choice. `ca.peetvandesande.com` is repointable;
   `pistis.home` would not have been. Pistis is the *origin* that holds the
   files — it is not what the certificate names, and it may not be what answers
   that name.

   This applies to strings frozen into certificates, and **only** those. The CA
   API URL is not one of them; see below.

Also worth knowing: step-ca now binds the **wildcard**, `[::]:8443`, and so
has no `wait-for-address` drop-in — the file is gone. It bound
`192.168.8.55:8443` and needed one until the IPv6 rollout; `address` takes a
single value, so a wildcard is the only way to serve both families, and it is
how nginx on the same host has always worked. `net.ipv6.bindv6only` is 0, so
one `[::]` socket covers IPv4 as well. The CA's own certificate gains the ULA
through `dnsNames`, which is where step-ca reads its SANs from.

## URLs and paths that are baked into certificates

These appear inside issued certificates and **cannot be renamed** without
reissuing everything below them:

- `http://ca.peetvandesande.com/g3/root.crl` — G3's `crlDistributionPoints`
- `http://ca.peetvandesande.com/g3/root.crt` — G3's `authorityInfoAccess`
  (caIssuers). Both name the *root*, because the root is what issued G3.

`https://pistis.home:8443`, the CA API URL, is **not** on this list and is
deliberately a hostname. Invariant 7 governs strings frozen into certificates;
this one is a step-ca endpoint that is replaced along with step-ca. Binding it
to the tool's host is honest — a settled decision, not an outstanding one.

`http://ca.peetvandesande.com/g2/root.crl` is on that list too — not in G3,
but in all three certificates the root signed before it (`rootca/index.txt`
serials 1000-1002, valid to December 2026, November 2029 and June 2035). It is
the **only** `/g2/` object: none of the three has an `authorityInfoAccess` at
all, and the `/g2/intermediate.crl` and `/g2/intermediate.crt` in
`rootca/openssl.cnf` are in sections that were never applied to anything.

**`/g2/` is served only on ruby, statically, and pistis holds none of it.**
pistis is the G3 issuing CA; the pre-G3 hierarchy is not live and its one file
changes only when something is revoked off the root. `install-ruby.sh` installs
it into `/var/www/ca.g2` from `rootca/crl/root.crl` in ruby's clone, so it
exists once in git. It is the same object as `/g3/root.crl` — one root, one CRL
— but a copy rather than a proxy, so **re-run `install-ruby.sh` after any
`root-crl.sh`**: `deploy.sh` reaches pistis and nothing reaches ruby. Both that
script and `verify.sh` assert the two still match, so forgetting fails a check
rather than leaving two CRLs for one root.

`ca.peetvandesande.com` is **split-horizon**. Inside the lab, Pythia is
authoritative for that single name and answers `192.168.8.55`, so pistis serves
`/g3/` at exactly the URL the certificate names. Publicly it is a CNAME to ruby
(145.239.73.18), which **reverse-proxies `/g3/` to pistis over wg1** and serves
`/g2/` from disk — `ca/ruby/`, installed by `scripts/install-ruby.sh` from
ruby's own clone. For `/g3/` pistis is the single origin either way; nothing is
synced outward, so those two views cannot drift.

Three pieces make that work and **none of them works alone** — the zone on
Pythia, the forward-zone on Delphi, and an `addNTA()` because
`peetvandesande.com` is DNSSEC-signed. See `homelab/dns/CLAUDE.md`.

Four things about ruby's half of that are load-bearing:

- **`/g3/` is proxied through a variable, not a literal.** `proxy_pass
  http://$pistis$request_uri` plus a `resolver` makes nginx resolve
  `pistis.home` per request. A literal — name or address — is resolved once at
  config load, and for a name a failure there is fatal: `host not found in
  upstream`, nginx does not start, and sogode.com and webmail go with it,
  because they share that nginx. wg1 or `named` being slow at boot is enough.
  Through a variable the same failure is a 502 on `/g3/` alone, which the cache
  absorbs. `install-ruby.sh` asserts the variable is still there.

  The resolver is `127.0.0.1` with `ipv6=off`. ruby's `named` needed a `home`
  static-stub in its **internal** view, not only the wireguard one, for this to
  resolve at all — `wireguard/ruby/services/etc/bind/named.conf.local`.
  `ipv6=off` is about what is published, not what exists: pistis's **ULA**
  (`fd33:5692:1834:1000::/64`) is in wg1's AllowedIPs and would be reachable,
  and its nginx already listens on `[::]:80`. Its **GUA** is the unusable one —
  deliberately outside wg1's AllowedIPs, and it renumbers with the ISP lease.
  What is missing is the record: `home.` carries no AAAA for any host, and
  step-ca binds `192.168.8.55:8443` alone, so pistis is not dual-stack, only
  its nginx is. Turn this on by adding the AAAA in `dns/` first.

- **Never proxy to `ca.peetvandesande.com` itself.** ruby's BIND has no local
  copy of `peetvandesande.com`, so ruby resolves that name to the public CNAME
  — itself — and `proxy_pass` to it loops into the same server block. The
  upstream is `pistis.home`; the Host header is the public name.
- **No HTTPS, and no redirect to it.** The frozen URLs are `http://`; a client
  that needs these files in order to establish trust cannot be asked for TLS
  first, and to a fetcher that speaks no TLS a 301 looks like a failure. The
  `http_ca` module in `outside/` probes for a bare 200 with redirects
  unfollowed, so adding one fails a probe.
- **The nginx cache is not an optimisation.** ruby answers the only copy of
  these URLs the internet can reach, and the origin is behind a home fibre
  line. `proxy_cache_use_stale` plus `inactive=30d` is what stops an outage at
  home becoming an outage of revocation checking.

This **works for real clients**, and since ruby started proxying it works from
either side: on the LAN the name resolves to pistis, off it to ruby, and the
CRL returns 200 both ways. `verify.sh`'s third check uses the workstation's own
resolver, so it no longer WARNs just because the workstation is on a VPN — a
fourth check pins the name to ruby's public address and tests that path on
purpose.

Adding a DNS alias for the CA API means adding it to `dnsNames` in `ca.json`
too, or TLS to that name fails.

## Enrolling a host

`scripts/enrol.sh <ip> <name>` (or `--all`) is how anything gets a certificate.
It installs the G2 root and G3 intermediate as trust anchors, mints a
single-use token on pistis, and has the target redeem it.

**The private key is generated on the target and never moves, and the JWK
provisioner password never leaves pistis.** That is the point of the token: a
compromised service host yields one certificate, not the ability to mint any.
Do not "simplify" this into issuing centrally and copying keys around.

Enrolled hosts get `/etc/homelab-tls/`:

| Path | What |
|---|---|
| `host.crt` | leaf **+ G3 intermediate**, `root:tlscert 0644` |
| `host.key` | `root:tlscert 0640` — read via the `tlscert` group |
| `root_ca.crt` | the G2 root, for anything that wants an explicit anchor |
| `post-renew.d/` | per-service hooks, run only when the cert actually changed |

Renewal is a daily timer running `step ca renew`, authenticated by the existing
certificate over mTLS — no provisioner secret on the host.

## Fleet TLS invariants — do not "simplify" these away

Each of these was found by something breaking.

1. **The G3 intermediate must be in each host's system trust store**, not just
   `host.crt`. Most servers here send a full chain because `host.crt` *is*
   leaf+intermediate — but .NET is not one of them. Jellyfin loads its PKCS#12
   with `X509Certificate2`, which takes only the first certificate, so Kestrel
   served a bare leaf and every client failed with "unable to verify the first
   certificate". With the intermediate in the store, .NET builds and sends the
   chain itself.

2. **Group membership alone does not get a sandboxed unit access to the key.**
   Debian's `prometheus.service` sets `PrivateUsers=true`, which puts it in a
   user namespace where supplementary groups are not mapped — so adding
   `prometheus` to `tlscert` is not enough. The drop-in names
   `SupplementaryGroups=tlscert` explicitly. Turning `PrivateUsers` off would
   also "work"; don't.

3. **A host that stays off past its expiry cannot renew itself.** The CA has
   `allowRenewalAfterExpiry: false` and renewal is authenticated by the
   certificate being renewed. Recovery is re-running `enrol.sh` for that host,
   which mints a fresh token. Certificates are 30 days, renewal starts at 10
   days remaining, and the timer is `Persistent=true` so a host that was off
   overnight checks immediately rather than at the next midnight.

4. **`post-renew.d` is a directory, not a file.** Every host runs
   node-exporter, and most run something else too. A single `post-renew` file
   would mean the two stacks overwriting each other's hook.

5. **Consumers address hosts by name; certificates carry IP SANs for both
   families.** Addressing by IP was forced before the DHCP cutover to Themis,
   when nothing resolved `.home`, and the IPv6 rollout retired it: Prometheus
   targets, Grafana's two datasources and Alloy's push URL are `<name>.home`,
   verified against the DNS SAN each certificate already carried.

   **The ULA IP SAN is discovered, never tabulated.** `enrol.sh` reads it off
   the target — it is SLAAC from the MAC, so a container rebuilt with a new MAC
   gets a new one and a list in the script would go stale in silence. Only
   `fd33:5692:1834:1000::/64`: the ISP prefix renumbers with the lease, and an
   address frozen into a 30-day certificate that stops existing mid-life is
   worse than no SAN. A host with no ULA simply gets IPv4 SANs.

   The 127.0.1.1 trap turned out not to bite. A container does resolve its own
   FQDN to loopback under DHCP, but the services this affects bind the wildcard
   and answer there, and TLS verifies on the **name**, not on whichever address
   it resolved to. It would bite a service bound to one specific non-loopback
   address.

   `homelab-tls-renew` keeps the IP deliberately: renewing every certificate in
   the lab should not depend on DNS being healthy.

## When you add a container

The homelab rule applies here as everywhere: add its A and PTR records to
`dns/pythia/var/lib/powerdns/zones/`, bump both serials, run
`dns/scripts/deploy.sh`, and add the `node` target on 192.168.8.53.
`pistis` (`.55`) and the `ca.home` CNAME are already done.
