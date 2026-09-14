# Prometheus

CT 103, **192.168.1.53**. Serves its API over TLS on `:9090` and scrapes the
migrated services over TLS.

## Working on this

`root/` mirrors the container filesystem and is the source of truth. **Never
edit `/etc/prometheus/prometheus.yml` on .53.** `scripts/deploy.sh` pushes and
validates with `promtool`; `scripts/verify.sh` asserts every target is up.

Deploy **after** `node-exporter/`, and **before** `grafana/`.

## Invariants

1. **`tls_config` is spelled out on every job; do not hoist it into a YAML
   anchor.** Prometheus parses this file strictly and rejects any unrecognised
   top-level key, so an anchor block fails with `field tls_defaults not found
   in type config.plain`. Four copies of two lines is the price.

2. **`SupplementaryGroups=tlscert` in the drop-in is load-bearing.** The
   packaged unit sets `PrivateUsers=true`, which puts Prometheus in a user
   namespace where supplementary groups are not mapped — so adding the
   `prometheus` user to `tlscert` does not by itself grant read access to
   `/etc/homelab-tls/host.key`. Naming the group explicitly does. Do not
   "fix" this by disabling `PrivateUsers`.

3. **Targets are IP addresses, not `.home` names.** Nothing on this LAN
   resolves `.home` until the DHCP cutover to Themis, containers included.
   Every certificate carries an IP SAN for exactly this reason. The self-scrape
   uses `localhost:9090`, which is in this host's SANs too.

4. **The `node` job must match `FLEET` in `ca/scripts/enrol.sh`.** A host
   enrolled but not listed here is unmonitored; a host listed here but not
   enrolled fails its scrape the moment node-exporter goes TLS.

5. **Every scrape job is TLS except `navidrome` (and the broken `pve`).**
   Navidrome has one listener for both UI and `/metrics`, and the UI is
   deliberately plain HTTP because media streaming is LAN-only — see
   `navidrome/CLAUDE.md`. Jellyfin keeps `:8920` HTTPS alongside its plain UI
   for exactly this scrape. The `dns` job reaches nginx, not the PowerDNS
   webservers directly — none of those can serve TLS, so each backend binds
   loopback behind an nginx that allows only .53. The target addresses are
   unchanged. A 403 from anywhere else is that ACL working.

## Known broken, pre-existing

The `pve` job is down because `prometheus-pve-exporter` is not running on
`127.0.0.1:9221`. Nothing to do with TLS; it was down before this change.
`verify.sh` reports it as WARN.
