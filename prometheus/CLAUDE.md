# Prometheus

CT 103, **192.168.8.53**. Serves its API over TLS on `:9090` and scrapes the
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

3. **Targets are IP addresses, not `.home` names.** This was once forced —
   nothing resolved `.home` — and since the DHCP cutover to Themis it is a
   choice: names resolve, and every certificate carries a DNS SAN beside its
   IP SAN, so a name would verify. Renaming 22 targets buys nothing and a
   container resolves its own FQDN to 127.0.1.1 under DHCP. The self-scrape
   uses `localhost:9090`, which is in this host's SANs too.

4. **The `node` job must match `FLEET` in `ca/scripts/enrol.sh`.** A host
   enrolled but not listed here is unmonitored; a host listed here but not
   enrolled fails its scrape the moment node-exporter goes TLS.

5. **Every scrape job is TLS except `navidrome`, `traefik`, `blackbox`,
   `outside-*` and the broken `pve`.** `blackbox` is this host's own exporter
   on 127.0.0.1:9115 (invariant 7). The `outside-*` blackbox exporters on ruby and jennie
   listen only on their dummy0 address, reachable only through WireGuard, and
   neither server holds a lab certificate - `outside/CLAUDE.md`. Navidrome has one listener for both UI and `/metrics`, and the UI is
   deliberately plain HTTP because media streaming is LAN-only — see
   `navidrome/CLAUDE.md`. Jellyfin keeps `:8920` HTTPS alongside its plain UI
   for exactly this scrape. The `dns` job reaches nginx, not the PowerDNS
   webservers directly — none of those can serve TLS, so each backend binds
   loopback behind an nginx that allows only .53. The target addresses are
   unchanged. A 403 from anywhere else is that ACL working. The `docker` job
   on moby works the same way: the engine serves plain HTTP on loopback and
   nginx fronts it on `:9323`. `traefik`, also on moby, is plain HTTP on
   .74:8080 — a migrated stack that predates this repo's TLS posture and
   carries its own certificates for the sites it fronts.

6. **The `grafana` job is not for graphs.** `grafana_alerting_*` is the only
   thing that can report that the alerting itself has stopped - a rule naming a
   datasource uid that no longer exists never evaluates and never errors. Without
   this job, every alert in `grafana/` is unmonitored.

7. **The blackbox exporter here probes what a LAN client experiences**:
   internet by ping (two providers per family), ruby and jennie over their
   tunnels, DNS through Themis end to end (public, `.home`, DoT), and a
   verified TLS handshake to every lab certificate. Config is
   `root/etc/prometheus/blackbox.yml`, targets the `blackbox` job, rules
   `grafana/.../alerting/probes.yaml`. Its TLS target list repeats the `node`
   job's hosts - keep them in step.

8. **ICMP works through `net.ipv4.ping_group_range`, not `CAP_NET_RAW`.** The
   package's `setcap` leaves an empty file-capability xattr on the binary in
   this unprivileged container, and a binary with file capabilities drops the
   unit's ambient ones on exec, so a capability drop-in is silently useless.
   `root/etc/sysctl.d/60-ping-group-range.conf` enables unprivileged echo
   sockets instead, for gids 0-65535: in a user namespace the range may only
   hold mapped gids, so systemd's usual `0 2147483647` is refused.

## Known broken, pre-existing

The `pve` job is down because `prometheus-pve-exporter` is not running on
`127.0.0.1:9221`. Nothing to do with TLS; it was down before this change.
`verify.sh` reports it as WARN.
