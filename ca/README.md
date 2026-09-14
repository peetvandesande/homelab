# CA — operational notes

A three-tier private PKI for the lab: an offline RSA-4096 root from 2016, a new
ECDSA P-256 intermediate, and leaf certificates issued by step-ca.

```
Peet van de Sande Root Certificate G2      rootca/ — offline, on the workstation
  C=GB, ST=England, L=London               RSA-4096, expires Dec 2046
        │
        ▼
Peet van de Sande Intermediate CA G3       pistis (192.168.1.55), step-ca 0.30.2
  C=FR, ST=Bouches-du-Rhone                ECDSA P-256, pathlen:0, ~10 years
        │
        ▼
leaf certificates                          ACME (auto) or JWK (by hand)
```

## The one thing to understand

**The root key never leaves the workstation.** `rootca/private/root.key` is
passphrase-protected and is used exactly twice in normal life: to sign a new
intermediate, and to regenerate the root CRL. Both are workstation-side scripts
that prompt for the passphrase and never store it. Pistis holds only the G3 key.

Everything else is the usual repo-is-the-truth arrangement: **never edit config
on pistis**, edit `pistis/` here and run `scripts/deploy.sh`.

## Scripts

| Script | Runs on | Does |
|---|---|---|
| `scripts/bootstrap.sh` | the Proxmox host | Creates CT 101 and installs step-ca/step-cli. Idempotent. |
| `scripts/make-intermediate.sh` | workstation | Mints the G3 key and CSR, signs it with the root, regenerates the root CRL. **Prompts for the root passphrase.** |
| `scripts/root-crl.sh` | workstation | Regenerates the root CRL on its own. Run after any `openssl ca -revoke`. |
| `scripts/deploy.sh` | workstation | Pushes `pistis/`, installs CA material, brings step-ca and nginx up. Idempotent. |
| `scripts/verify.sh` | workstation | End-to-end smoke test, including a real certificate issuance. Exits non-zero on failure. |

Order from nothing: `bootstrap.sh` → `make-intermediate.sh` → `deploy.sh` →
`verify.sh`.

## What holds a certificate today

Nine hosts are enrolled — every container plus lenora — and these services
serve TLS off the G3 intermediate:

| Host | Service | Port |
|---|---|---|
| all nine | prometheus-node-exporter | 9100 |
| .53 | Prometheus API | 9090 |
| .54 | Grafana UI | 3000 |
| .60 | Jellyfin | 8920 (8096 still plain) |
| .61 | Navidrome | 4533 |
| .50 | dnsdist DoT / DoH | 853 / 443 |
| .50/.51/.52 | PowerDNS metrics, via nginx | 8083 / 8082 / 8081 |
| .21 | Proxmox VE web GUI | 8006 |

Each lives in its own directory at the top of `homelab/`, with the fleet-wide
node-exporter in `node-exporter/`. **Deploy order matters**: node-exporter
first, then prometheus, then the rest — see each stack's CLAUDE.md.

## Getting a certificate

Point an ACME client at the directory URL. Nothing else is needed — the CA
issues to any name, there is no account approval step.

```
https://pistis.home:8443/acme/acme/directory
```

Clients must trust the G2 root first. Pistis serves it, unauthenticated, at
`http://pistis.home/g3/root.crt`, along with `chain.pem`, `intermediate.crt`
and `root.crl`.

Note the certificate itself names `http://ca.peetvandesande.com/g3/`, not
pistis — see "Deliberate decisions". Pistis is the origin that holds the files;
that domain is what relying parties are told to ask.

- **caddy** — `acme_ca https://pistis.home:8443/acme/acme/directory`
- **Traefik** — `certificatesResolvers.step.acme.caServer`
- **certbot** — `--server .../acme/acme/directory`
- **dns-01** — supported, and needs no credentials on the CA side. step-ca only
  *reads* `_acme-challenge`; the client writes it into `home.` via Pythia's API.
  That key lives in `homelab/dns/secrets.env`, not here.

By hand, for something that cannot do ACME (30 days by default, a year at most):

```sh
step ca certificate foo.home foo.crt foo.key \
  --provisioner admin --ca-url https://pistis.home:8443 \
  --root /etc/step-ca/certs/root_ca.crt
```

The `admin` password is `STEP_CA_JWK_PASSWORD` in `secrets.env`; on pistis
itself it is already at `/etc/step-ca/secrets/jwk-password`.

## Trusting the root on a client

```sh
step ca bootstrap --ca-url https://pistis.home:8443 --fingerprint <root fingerprint> --install
```

`deploy.sh` prints the fingerprint when it finishes. Without step-cli, fetch
`http://pistis.home/g3/root.crt` and add it to the system store by hand.

## Revocation

Two separate mechanisms, and it matters which one you need.

- **A leaf** — `step ca revoke --cert foo.crt`. step-ca handles it and serves
  the result from its own CRL at `https://pistis.home:8443/1.0/crl`.
- **The G3 intermediate itself** — that is the root's job:
  `openssl ca -config … -revoke intermediate/certs/intermediate-g3.crt`, then
  `scripts/root-crl.sh`, then `scripts/deploy.sh` to publish the new CRL.

The root CRL is generated with a **ten-year** validity. An offline root cannot
honour a 30-day CRL, and an expired CRL fails closed in anything that checks
it. The cost is real: a revocation only reaches clients when someone
regenerates and redeploys by hand.

## Deliberate decisions

- **The G3 subject is `C=FR, ST=Bouches-du-Rhone`, the root's is `C=GB,
  ST=England`.** The root's `policy_strict` requires both to match, so
  `make-intermediate.sh` signs with `-policy policy_loose`.
  `rootca/openssl.cnf` is left exactly as it was — it is the record of how the
  g2 root was run, not live configuration.
- **CRL and AIA point at `http://ca.peetvandesande.com/g3/`, a domain rather
  than a host.** These two strings are frozen into G3 for ten years and cannot
  be changed without reissuing it and every leaf beneath it, so they have to
  outlive pistis, step-ca and any other implementation choice. A domain we own
  can be repointed at whatever serves it in 2031; `pistis.home` could not.
  The `/g3/` path continues the g2 convention.
- **They are plain HTTP.** Not an oversight: these are the files a client needs
  *in order to* establish trust, so requiring TLS would be circular. All of
  them are signed objects that verify on their own. Both URLs name the *root*,
  because the root is what issued G3.
- **The CA API URL, `https://pistis.home:8443`, is deliberately a hostname**,
  and the rule above does not apply to it. CDP and AIA are frozen into
  certificates for ten years and have to outlive any implementation choice;
  the API URL is a step-ca endpoint that gets replaced along with step-ca. It
  is bound to the tool, so binding it to the tool's host costs nothing.
- **`authority.enableAdmin` is `false`.** With it true, provisioners live in
  the badger DB and `ca.json` here would be a lie.
- **The JWK provisioner is minted once** and kept in `secrets.env`. Re-minting
  changes the `kid` and breaks every client that has bootstrapped against it.
- **ACME certificates last 24 hours** by default, 90 days at most. Anything on
  ACME renews unattended, so a long lifetime buys nothing and makes revocation
  slow.
- **Package versions are pinned** in `bootstrap.sh`. An upstream release should
  not be able to change the signing behaviour of a running CA unattended. Note
  the `-1` Debian revision — the `.deb` filenames carry it, the git tags do not.

## Not done yet

- **No certificate-expiry monitoring.** The `node` job covers the container,
  but step-ca 0.30 exposes no Prometheus endpoint, so nothing watches whether
  issued certificates are actually being renewed. `blackbox_exporter` with the
  `tls_connect` module on .53 is the way in, and there is no Grafana dashboard
  or alert off any of it.
- **No backup of the G3 key.** `/etc/step-ca/secrets/intermediate_ca_key` on
  pistis and nowhere else. It is recoverable — re-run `make-intermediate.sh`
  and re-issue — but that is a rebuild, not a restore.
- **`/g3/` is only served on the inside.** `ca.peetvandesande.com` is
  split-horizon: Pythia is authoritative for that one name and answers
  `192.168.1.55`, so pistis serves the CRL and AIA at exactly the URL the
  certificate names. Publicly the name is still a CNAME to an OVH VPS
  (145.239.73.18) that this repo does not manage, where `/g3/` returns 404 — as
  does `/g2/`, dangling since 2016. Two consequences:
  - **No client benefits yet**, because nothing on the LAN uses Themis. The
    router still hands out the gateway, so every host resolves the name to the
    VPS and gets a 404 — revocation checking and AIA chain-building are still
    broken in practice. `verify.sh` reports this as WARN rather than FAIL so
    the smoke test stays a usable gate.
  - **Anything off the LAN can never check revocation**, split-horizon or not.
    If that matters, publish the four files from pistis's `/var/www/g3` on the
    VPS as well; the two would then agree.
- **`ca.home` is a CNAME to `pistis.home`**, and works for TLS only because
  `ca.json` lists it in `dnsNames`. If you add another alias, add it there too
  or TLS to that name fails.
- **The root CRL is empty and always has been.** Nothing has ever been revoked
  off the G2 root, including the G2 intermediate, which is still valid in
  `rootca/index.txt`.
