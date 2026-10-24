# CA — operational notes

A three-tier private PKI for the lab: an offline RSA-4096 root from 2016, a new
ECDSA P-256 intermediate, and leaf certificates issued by step-ca.

```
Peet van de Sande Root Certificate G2      rootca/ — offline, on the workstation
  C=GB, ST=England, L=London               RSA-4096, expires Dec 2046
        │
        ▼
Peet van de Sande Intermediate CA G3       pistis (192.168.8.55), step-ca 0.30.2
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
| `scripts/install-ruby.sh` | **ruby**, from `~/homelab` | Installs the public `ca.peetvandesande.com` vhost that proxies `/g2/` and `/g3/` back to pistis. Idempotent. |
| `scripts/verify.sh` | workstation | End-to-end smoke test, including a real certificate issuance. Exits non-zero on failure. |

Order from nothing: `bootstrap.sh` → `make-intermediate.sh` → `deploy.sh` →
`verify.sh`. `install-ruby.sh` is separate because it runs on a host outside
the lab and only has to be re-run when its own vhost changes — it serves
whatever pistis is publishing at the time.

## What holds a certificate today

Twelve hosts are enrolled — every container, the hermes VM and lenora — and these services
serve TLS off the G3 intermediate:

| Host | Service | Port |
|---|---|---|
| all twelve | prometheus-node-exporter | 9100 |
| all twelve | Grafana Alloy `/metrics` | 12345 |
| .53 | Prometheus API | 9090 |
| .54 | Grafana UI | 3000 |
| .60 | Jellyfin `/metrics` for Prometheus | 8920 (UI is plain HTTP on 8096) |
| .50 | dnsdist DoT / DoH | 853 / 443 |
| .50/.51/.52 | PowerDNS metrics, via nginx | 8083 / 8082 / 8081 |
| .56 | Loki API and `/metrics` | 3100 |
| .27 | Docker Engine `/metrics`, via nginx | 9323 |
| .21 | Proxmox VE web GUI | 8006 |
| .57 | mailcow UI and SOGo; SMTP, IMAP | 443; 25/465/587, 993 |

Each lives in its own directory at the top of `homelab/`, with the fleet-wide
node-exporter in `node-exporter/`. **Deploy order matters**: node-exporter
first, then prometheus, then the rest — see each stack's CLAUDE.md.

## Getting a certificate

Point an ACME client at the directory URL. Nothing else is needed — the CA
issues to any name, there is no account approval step.

<https://pistis.home:8443/acme/acme/directory>

Clients must trust the G2 root first. Pistis serves it, unauthenticated, at
<http://pistis.home/g3/root.crt>, along with `chain.pem`, `intermediate.crt`
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
<http://pistis.home/g3/root.crt> and add it to the system store by hand.

## Where the published files are served

`/g2/` and `/g3/` are reachable at `ca.peetvandesande.com` from both sides of
the lab's edge:

| From | Resolves to | `/g3/` | `/g2/` |
|------|-------------|--------|--------|
| the LAN | `192.168.8.55` | pistis, directly | **not served** |
| the internet | `145.239.73.18` | ruby, proxying to pistis over wg1 | ruby, statically |

**The two generations are served differently on purpose.** `/g3/` belongs to
the live issuing CA, so ruby reverse-proxies it and pistis stays the single
origin — `scripts/deploy.sh` publishes there and nothing has to be synced
outward, so the inside and outside views cannot drift. `/g2/` belongs to a
hierarchy that is not live: its one file changes only when something is
revoked off the root, and pistis is a G3 host that holds no `/g2/` at all, so
there is nothing there to proxy to. ruby serves it from `/var/www/ca.g2`.

**ruby had a dead `ca.peetvandesande.com` block before this**, inside
`sites-available/peetvandesande.com` (which this repo does not manage). It had
`root /var/www/ca`, a directory that does not exist, so it answered 404 to
everything — this is what "dangling since 2016" meant, and why probing the
public name returned 404 rather than hitting nginx's default server. Its
`access_log` file had never been created, so it had served no request at all.
It was deleted on 24 October 2026; `install-ruby.sh` refuses to run while
another enabled site claims the name, because nginx would otherwise resolve
the collision itself with nothing but a warning.

The vhost is `ruby/etc/nginx/sites-available/ca.peetvandesande.com`, installed
by `scripts/install-ruby.sh` run from ruby's own clone:

```
ssh ruby 'cd ~/homelab && git pull && sudo ca/scripts/install-ruby.sh'
```

**And then `outside/install.sh` on jennie**, or the monitoring half is dead
weight. The `http_ca` module lives in `outside/etc/prometheus/blackbox.yml`,
which is installed on the vantage servers and not by this directory, so
adding the Prometheus targets is only two thirds of the job. A blackbox
exporter asked for a module it does not have answers **400 Bad Request** —
which reads exactly like ruby rejecting the request, and cost a round of
misdiagnosis on 24 October 2026. Check with
`curl -s 'http://192.168.254.2:9115/probe?module=http_ca&target=http://145.239.73.18/g3/root.crl'`:
`Unknown module "http_ca"` is the exporter, not the origin.
```

**`/g2/` holds exactly one file: `root.crl`.** All three certificates the root
signed before G3 carry `crlDistributionPoints =
http://ca.peetvandesande.com/g2/root.crl` and **no `authorityInfoAccess` at
all**, so there is no AIA object to publish. They are `rootca/index.txt`
serials 1000–1002 — the G2 intermediate, expiring December 2026, and two squid
certificates running to November 2029 and June 2035 — so the path has to answer
for another nine years. `rootca/openssl.cnf` names `/g2/intermediate.crl` and
`/g2/intermediate.crt` in sections that were never applied to anything; nothing
fetches them and a 404 there is the honest answer.

It is the same object as `/g3/root.crl` — one root, one CRL — but a local copy
rather than a proxy, so the two *can* drift. `install-ruby.sh` installs it from
`rootca/crl/root.crl` in the clone, so it exists once in git, and asserts it
still matches what pistis is serving. **Re-run it after any `root-crl.sh`**:
`deploy.sh` reaches pistis, nothing reaches ruby. `verify.sh` checks the same
equality from the workstation, so a forgotten update fails the smoke test.

Three things in ruby's config are load-bearing and easy to undo by accident:

- **`/g3/` is proxied through a variable, not a literal.** `proxy_pass
  http://$pistis$request_uri` with a `resolver` forces nginx to resolve
  `pistis.home` per request. A literal name is resolved once, at config load,
  and a failure there is fatal — `host not found in upstream` and nginx does
  not start, taking sogode.com and webmail with it, because they share that
  nginx. wg1 or `named` being slow at boot is enough. Through a variable the
  same failure is a 502 on `/g3/` alone, which the cache absorbs.
- **The resolver is `127.0.0.1` with `ipv6=off`.** ruby's own `named` has a
  `home` static-stub pointing at Pythia — in the **internal** view as well as
  the wireguard one, which is a change this needed
  (`wireguard/ruby/services/etc/bind/named.conf.local`). `ipv6=off` reflects
  what is published rather than what exists: pistis's ULA is routed over wg1
  and its nginx listens on `[::]:80`, so a ULA AAAA would work, but `home.`
  carries no AAAA for any host and step-ca binds `192.168.8.55:8443` alone.
  Adding the record in `dns/` is the prerequisite for flipping it.
- **No HTTPS and no redirect to it.** The URLs frozen into the certificates are
  `http://`, many CRL and AIA fetchers speak no TLS, and to those a 301 is
  indistinguishable from a failure. The `http_ca` blackbox module in `outside/`
  asserts a bare 200 with redirects unfollowed, so adding one breaks a probe
  rather than quietly breaking clients.

## Revocation

Two separate mechanisms, and it matters which one you need.

- **A leaf** — `step ca revoke --cert foo.crt`. step-ca handles it and serves
  the result from its own CRL at <https://pistis.home:8443/1.0/crl>.
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

## Losing pistis is a restore, not a rebuild

The G3 key exists in three places: `/etc/step-ca/secrets/intermediate_ca_key`
on pistis, `intermediate/private/intermediate-g3.key` on the workstation
(encrypted PKCS#8, gitignored), and one copy in a password manager outside the
lab. This file deliberately does not say which, since that account is itself a
target. The certificate needs no backup — `intermediate/certs/
intermediate-g3.crt` is committed, because a certificate is public.

To restore: put the key back at `intermediate/private/intermediate-g3.key` and
run `scripts/deploy.sh`, which pushes the key and certificate and brings
step-ca up. **Nothing is re-issued and no client re-bootstraps**, because the
G3 key is unchanged and every leaf under it still chains to the same root.
`make-intermediate.sh` is for a *lost key*, not a lost host — running it would
mint a new G3 and invalidate every certificate in the lab.

**The backup is useless without `STEP_CA_KEY_PASSWORD` from `secrets.env`**,
which is gitignored and exists nowhere else in this repo. Back that up with the
key, or the key cannot be decrypted. Verified on 24 October 2026 that the
passphrase in `secrets.env` decrypts the workstation copy to the same public key
the live G3 certificate carries:

```sh
set -a; . ./secrets.env; set +a
openssl pkey -in intermediate/private/intermediate-g3.key \
  -passin env:STEP_CA_KEY_PASSWORD -pubout | openssl sha256
openssl x509 -in intermediate/certs/intermediate-g3.crt -noout -pubkey | openssl sha256
```

The root key is a different matter and deliberately so: it never leaves the
workstation and its passphrase is never written down — `CLAUDE.md` invariant 1.
It is needed only to mint a new intermediate or regenerate the root CRL, so
losing it costs a new generation of the hierarchy, not the running lab.

## Not done yet

- **The G2 intermediate expires 19 December 2026** (`rootca/index.txt` serial
  1000). Nothing chains through it: the two squid certificates were signed by
  the *root* directly, not by it, so its expiry takes nothing with it. It is
  listed here so that is a recorded conclusion rather than a surprise.
- **`ca.home` is a CNAME to `pistis.home`**, and works for TLS only because
  `ca.json` lists it in `dnsNames`. If you add another alias, add it there too
  or TLS to that name fails.
- **The root CRL is empty and always has been.** Nothing has ever been revoked
  off the G2 root, including the G2 intermediate, which is still valid in
  `rootca/index.txt`.
