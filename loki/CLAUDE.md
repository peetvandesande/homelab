# Loki

CT 102, **192.168.1.56**. Log store, API over TLS on `:3100`, single binary
with filesystem storage and 30-day retention.

## Working on this

`root/` mirrors the container filesystem and is the source of truth.
`scripts/bootstrap.sh` creates the container on lenora (run it *on* lenora);
`scripts/deploy.sh` pushes the config; `scripts/verify.sh` checks the API, the
chain, an ingest/query round-trip, the Prometheus scrape and the trust path
from Grafana.

Deploy **after** `ca/scripts/enrol.sh 192.168.1.56 loki` — the config names
the certificate and Loki will not start without it.

## Invariants

1. **Loki binds the wildcard, so it has no `wait-for-address` drop-in.** Add a
   specific `http_listen_address` and it needs one.

2. **`SupplementaryGroups=tlscert` in the drop-in is how Loki reads the key.**
   The packaged unit runs as `loki`; the key is `root:tlscert 0640`.

3. **Grafana's datasource URL is an IP** (`grafana/.../datasources/loki.yaml`),
   same reason as every other consumer: nothing resolves `.home` until the
   DHCP cutover to Themis. Switch to a name after, not before.

4. **The package is pinned and held** (`apt-mark hold loki`). Loki's schema and
   config keys move between majors; bump `LOKI_VER` in `bootstrap.sh` together
   with `root/etc/loki/config.yml`, and run `loki -verify-config` on the pair.

5. **gRPC (`:9096`) is loopback-only.** Nothing outside the container needs it
   in single-binary mode, and it is not TLS.

## Shippers

Every enrolled host runs Grafana Alloy (`alloy/`) and pushes its journal here
over TLS. `limits_config.reject_old_samples_max_age` (168h) and Alloy's
`max_age` (166h) are a pair — change one, change the other.
