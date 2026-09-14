# Grafana

CT 104, **192.168.1.54**. UI over TLS on `:3000`, reaching Prometheus over TLS.

## Working on this

`root/` mirrors the container filesystem and is the source of truth.
`scripts/deploy.sh` pushes it; `scripts/verify.sh` checks the UI, the chain and
the trust path to Prometheus.

Deploy **after** `prometheus/` — the datasource pushed here points at `https`,
so doing it first leaves every dashboard broken in between.

## Invariants

1. **TLS is configured with `GF_*` environment variables in a systemd drop-in,
   not by editing `/etc/grafana/grafana.ini`.** That file is ~2000 lines of
   packaged defaults, currently untouched; owning a copy here would mean
   re-merging it on every Grafana upgrade. `GF_SERVER_*` overrides the ini and
   is the documented mechanism.

2. **Grafana verifies Prometheus against the system trust store**, into which
   `ca/scripts/enrol.sh` installed the G2 root. `tlsSkipVerify` stays `false` —
   this is a real check, and setting it true would make the whole migration
   decorative.

3. **The datasource URL is an IP.** `.home` does not resolve anywhere on this
   LAN until the DHCP cutover to Themis; the certificate carries an IP SAN for
   this. Change it to a name only after the cutover.

## Verifying trust without credentials

`verify.sh` does not log into Grafana. It asks the equivalent question from
grafana's own container — does a plain `curl` with no `--cacert` reach
Prometheus over TLS? — because that is the same system trust store Grafana
uses. A pass there means the datasource can connect.
