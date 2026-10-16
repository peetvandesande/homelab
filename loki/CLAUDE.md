# Loki

CT 102, **192.168.8.56**. Log store, API over TLS on `:3100`, single binary
with filesystem storage and 30-day retention.

## Working on this

`root/` mirrors the container filesystem and is the source of truth.
`scripts/bootstrap.sh` creates the container on lenora (run it *on* lenora);
`scripts/deploy.sh` pushes the config; `scripts/verify.sh` checks the API, the
chain, an ingest/query round-trip, the Prometheus scrape and the trust path
from Grafana.

Deploy **after** `ca/scripts/enrol.sh 192.168.8.56 loki` — the config names
the certificate and Loki will not start without it.

## Invariants

1. **Loki binds the wildcard, so it has no `wait-for-address` drop-in.** Add a
   specific `http_listen_address` and it needs one.

2. **`SupplementaryGroups=tlscert` in the drop-in is how Loki reads the key.**
   The packaged unit runs as `loki`; the key is `root:tlscert 0640`.

3. **Grafana's datasource URL is an IP** (`grafana/.../datasources/loki.yaml`),
   same reason as every other consumer. `.home` does resolve since the DHCP
   cutover to Themis, and the certificate carries a DNS SAN as well as an IP
   one, so a name would verify. It stays an IP because it works and because a
   container resolves its own FQDN to 127.0.1.1 under DHCP — a choice now,
   not a constraint.

4. **The package is pinned and held** (`apt-mark hold loki`). Loki's schema and
   config keys move between majors; bump `LOKI_VER` in `bootstrap.sh` together
   with `root/etc/loki/config.yml`, and run `loki -verify-config` on the pair.

5. **gRPC (`:9096`) is loopback-only.** Nothing outside the container needs it
   in single-binary mode, and it is not TLS.

## Shippers

Every enrolled host runs Grafana Alloy (`alloy/`) and pushes its journal here
over TLS. `limits_config.reject_old_samples_max_age` (168h) and Alloy's
`max_age` (166h) are a pair — change one, change the other.

The router cannot run Alloy, so it sends syslog **to** Loki's own Alloy:
`root/etc/alloy/router.alloy`, a UDP listener on `:1514` beside the fleet
`config.alloy`, labelled `host="router"`. `scripts/deploy.sh` pushes it and
proves the listener is open; `scripts/verify.sh` fails if no router line has
arrived in 15 minutes. Two things in that file are not obvious:

- **The source filter is a separate `loki.relabel`.** In the syslog source's
  own `relabel_rules`, a failed `keep` strips the relabelled labels and still
  forwards the entry, so a spoofed line arrived as `{host="router"}`. The
  address travels as a temporary `src` label and is dropped before Loki.
- **UDP, not TCP** — see `router/README.md`, "Logs".
