# CA

Smallstep three-tier Private Certificate Authority on Debian LXC container on `lenora`.

The intent is to use privately signed certificates across all services in homelab.

| CT  | Host   | IP           | Runs                | Role                              |
|-----|--------|--------------|---------------------|-----------------------------------|
| 101 | pistis | 192.168.1.55 | step-ca 0.30.2      | CA                                |

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

1. **The root key never leaves the workstation, and its passphrase is never
   written down.** It is not in `secrets.env` and must not be added. Only
   `scripts/make-intermediate.sh` and `scripts/root-crl.sh` ever touch it, both
   prompting interactively. Pistis holds the G3 key and nothing above it.

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

Also worth knowing: step-ca binds `192.168.1.55:8443` explicitly, so it needs
the `wait-for-address` drop-in like the DNS containers. nginx listens on the
wildcard and deliberately does not.

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

`ca.peetvandesande.com` is **split-horizon**. Publicly it is a CNAME to an OVH
VPS (145.239.73.18) that this repo does not manage, where nothing is published
under `/g3/` — nor under `/g2/`, dangling since 2016. Inside the lab, Pythia is
authoritative for that single name and answers `192.168.1.55`, so pistis serves
the files at exactly the URL the certificate names.

Three pieces make that work and **none of them works alone** — the zone on
Pythia, the forward-zone on Delphi, and an `addNTA()` because
`peetvandesande.com` is DNSSEC-signed. See `homelab/dns/CLAUDE.md`.

The remaining gap is that **no client uses Themis yet**, so in practice every
host on the LAN still resolves the name to the VPS and gets a 404. `verify.sh`
tests the split-horizon and the served paths as PASS, and reports the
real-client path as WARN until the DHCP cutover.

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

5. **Certificates carry IP SANs, and consumers address hosts by IP.** Nothing
   on this LAN resolves `.home` until the DHCP cutover to Themis — not even the
   containers, which inherit the router. Prometheus targets and Grafana's
   datasource URL are therefore IPs. After the cutover they can become names;
   until then, changing them breaks TLS verification.

## When you add a container

The homelab rule applies here as everywhere: add its A and PTR records to
`dns/pythia/var/lib/powerdns/zones/`, bump both serials, run
`dns/scripts/deploy.sh`, and add the `node` target on 192.168.1.53.
`pistis` (`.55`) and the `ca.home` CNAME are already done.
