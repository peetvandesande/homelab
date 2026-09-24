# Homelab

Proxmox VE 9.2 running Debian 13 LXC containers. Containers are the default
unit of deployment — only reach for a VM if something genuinely cannot run in
one.

`pct list` on the host is the source of truth for what exists. Don't trust an
inventory written down here; this file records *conventions*, not state.

## Host

- `lenora`, **192.168.1.21**, web UI on :8006
- 2 x Intel Xeon Gold 6262V, 256GB RAM
- Template: `local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst`

## Storage

Three ZFS mirrors. The pool names and the Proxmox storage IDs are not the same
thing, which trips people up:

| Pool      | Devices          | Storage IDs          | Use                                    |
|-----------|------------------|----------------------|----------------------------------------|
| `rpool`   | 2 x 256GB NVMe   | `local`, `local-zfs` | Proxmox boot; templates/ISOs in `local`|
| `ssdpool` | 2 x 480GB SSD    | `ssdpool`            | **container rootfs — the default**     |
| `hddpool` | 2 x 18TB HDD     | `hddpool`, `isos`    | bulk data                              |

Put container rootfs on `ssdpool`. Every container does this today except
navidrome, which is on `local-zfs` and is the odd one out rather than a pattern
to copy.

Bulk data stays on `hddpool` and is **mounted into** containers rather than
copied in — the media dataset `/hddpool/media` is mounted as `/var/media`,
read-only wherever the container only consumes it:

```
--mp0 /hddpool/media,mp=/var/media,backup=0,ro=1
```

## Container defaults

Every container is unprivileged, nesting-enabled and starts at boot:

```
--unprivileged 1 --features nesting=1 --onboot 1 --ostype debian --arch amd64
--rootfs ssdpool:<size>
```

- **No root password.** Import `~/Documents/sshkey.pub` (path on the
  workstation) via `--ssh-public-keys` at create time; root SSH is key-only
  thereafter.
- **IPv4 static** in 192.168.1.0/24, gateway 192.168.1.1. **IPv6 is SLAAC** —
  pass `ip6=auto` in `--net0`. The LAN has a real prefix
  (`2a01:cb1c:d:3500::/64`), so omitting it forgoes working IPv6.
- **Leave `--nameserver` unset** so the container inherits the host's resolver,
  unless it is part of the DNS stack itself.
- Always pass `--pool`.

Services bind to specific IPs, and in an LXC with ifupdown
`network-online.target` is reached *before* `eth0` has its address. If a
service binds to its static IP rather than the wildcard, give it a systemd
drop-in that waits for the address — otherwise it will intermittently fail to
bind on cold boot. See `dns/*/etc/systemd/system/*.d/wait-for-address.conf`
for the pattern, including the leading `+` needed to escape unit sandboxing.

## Pools, IDs and addresses

Pool names are **case-sensitive and exact** — `Non-Production`, not
`Non-production`. `pct create --pool Non-production` fails.

| Pool             | Container IDs | IP range              |
|------------------|---------------|-----------------------|
| `Infrastructure` | 100-199       | 192.168.1.50-.59      |
| `Production`     | 300-399       | 192.168.1.60-.69 †    |
| `Non-Production` | 200-299 †     | 192.168.1.70-.79 †    |

† Inferred from the existing pattern, not yet confirmed — Production is using
.60/.61 in practice, and Non-Production is currently empty with no range ever
written down. Confirm before relying on these.

Two things to be aware of:

- **The Infrastructure IP range is nearly gone** (.50-.56 used) while its ID
  range has 93 free slots. The ranges are badly matched in size; widen the IP
  allocation before it bites.
- **`lexie` (CT 100) sits at 192.168.1.26 and `moby` (CT 108) at
  192.168.1.27**, both outside the Infrastructure range they are pooled into.
  Moby additionally answers on .73 and .74 for the stacks it publishes,
  inside the range pencilled in for Non-Production. Existing anomalies —
  don't take them as precedent, and don't "tidy" them without asking.

## DNS

A three-container PowerDNS stack lives in `dns/` — see `dns/CLAUDE.md` and
`dns/README.md`. What matters at this level:

- **Internal domain is `home.`**, served authoritatively by Pythia
  (192.168.1.52). Reverse zone `1.168.192.in-addr.arpa.`.
- **`ca.peetvandesande.com` is overridden internally** to point at pistis
  (192.168.1.55), because the CA's certificates name it. Split-horizon on a
  DNSSEC-signed domain needs three coordinated pieces — read `dns/CLAUDE.md`
  invariant 5 before touching it.
- **When you add a container, add its A and PTR records** to
  `dns/pythia/var/lib/powerdns/zones/`, bump both serials, and run
  `dns/scripts/deploy.sh`.
- **Clients are intended to use Themis (192.168.1.50) as their only resolver**,
  via DHCP on the router. This cutover has not happened yet — everything still
  points at the gateway. The DNS containers themselves must stay on
  192.168.1.1 regardless, or Delphi cannot resolve at boot.

## Docker

Container workloads that are not worth an LXC run on `moby` (CT 108,
192.168.1.27) — Docker Engine with compose v2, one directory per stack under
`/opt/stacks`. See `moby/CLAUDE.md`. Nextcloud, Traefik and XWiki moved here
from the old moby at 192.168.1.25 (a machine this repo does not manage) in
September 2026; the rest of that host's stacks are still there.

Moby also holds **192.168.1.73 and .74** as extra addresses on `eth0`, one
per published stack, carried over so the migrated compose files did not have
to be rewritten. They are applied by a unit that `docker.service` requires,
not by interface config — Proxmox rewrites that on every start.

Moby has no mountpoint of its own. It carried `/hddpool/media` at `/var/media`
for Home Assistant until that moved to a VM in September 2026. A stack there
that wants bulk data gets it the same way the media containers do — the `mp0`
bind mount, not lenora's NFS export: an unprivileged LXC cannot mount NFS.

Reach for a container on moby when a service ships as an image and wants
nothing from the host; reach for an LXC when it wants to look like a machine.

## Monitoring

Prometheus (192.168.1.53) is used for **all** monitoring; Grafana
(192.168.1.54) for dashboards and alerting. Loki (192.168.1.56) is the log
store, wired into Grafana as a datasource. Every enrolled host ships its
systemd journal to it via Grafana Alloy (`alloy/`, one directory for all
eleven hosts, like `node-exporter/`); query by `{host="<name>"}` in Grafana. The
ESXi host `esther` (192.168.1.20, not enrolled, cannot run Alloy) reaches it
via a syslog/TLS relay and an hourly SMART pull, both on the loki container —
see `esxi/`.

**Prometheus config now lives in `prometheus/`, not on the host.** Editing
`/etc/prometheus/prometheus.yml` on .53 directly will be overwritten by the
next deploy.

When you stand up a service, wire it up in the same change — an unmonitored
service is not finished:

1. Install `prometheus-node-exporter` and enable it (the convention is every
   container exposes :9100).
2. Enrol the host: `ca/scripts/enrol.sh <ip> <name>`, then deploy
   `node-exporter/`. :9100 is TLS everywhere; an un-enrolled host cannot be
   scraped.
3. Add the target to `prometheus/root/etc/prometheus/prometheus.yml` **and** to
   `FLEET` in `ca/scripts/enrol.sh` — the `node` job for host metrics, plus a
   service-specific job if it exports its own. Give it `scheme: https` and the
   `tls_config` block if the service holds a lab certificate.
4. Ship its logs: `alloy/scripts/deploy.sh <ip>`, and add the host to the
   `alloy` job in `prometheus.yml` alongside its `node` entry.
5. `prometheus/scripts/deploy.sh`, then `prometheus/scripts/verify.sh`.

Prometheus targets are static and hand-maintained, so they rot when a service
moves. They have been wrong before — the `node` job was scraping .50/.51 as
"jellyfin"/"navidrome" long after both moved to .60/.61. If you renumber
anything, grep that file.

Known-broken and pre-existing: the `pve` job is down because the
prometheus-pve-exporter on 127.0.0.1:9221 is not running.

## TLS

Every service that speaks HTTP in this lab, except where noted, now serves TLS
off the lab's own CA (`ca/`). Eleven hosts are enrolled — all ten containers
plus lenora.

- **Get a certificate with `ca/scripts/enrol.sh <ip> <name>`.** It installs the
  trust anchors, mints a single-use token on pistis and has the target redeem
  it, so the private key is generated on the host and never moves. Renewal is
  a daily timer authenticated by the certificate itself.
- **Certificates carry IP SANs, and consumers address hosts by IP**, because
  nothing on this LAN resolves `.home` until the DHCP cutover to Themis —
  containers included, since they inherit the router. Switch to names after
  the cutover, not before.
- **Per-service TLS config lives in that service's own top-level directory**
  (`grafana/`, `jellyfin/`, `loki/`, `moby/`, `navidrome/`, `prometheus/`),
  one per container. `node-exporter/` and `alloy/` are the exceptions: one
  service on eleven hosts, so one directory rather than eleven copies.
- **Deploy order is load-bearing**: `node-exporter/` → `prometheus/` →
  everything else. The exporters go TLS first and Prometheus learns to speak
  TLS second, so there is a window where scrapes fail. Do them together.

- **A service that cannot serve TLS itself gets an nginx in front of it**,
  with the backend rebound to loopback. All three PowerDNS webservers work this
  way. Note that dnsdist *accepts* `certificate`/`key` on its webserver and
  then serves plain HTTP anyway, so "the config validated" is not evidence -
  connect and look.

Encrypted DNS is live on Themis: DoT on :853 and DoH on :443, off the same CA.

The Proxmox web GUI (lenora:8006) is on the CA too — see `proxmox/CLAUDE.md`.
Only `pveproxy-ssl.*` was replaced; `pve-ssl.*` stays on Proxmox's internal CA
because the cluster API depends on it.

Still plain HTTP, deliberately: the media UIs. Streaming is LAN-only, so
Jellyfin's :8096 and Navidrome's :4533 are unencrypted. Their metrics scrapes
stay TLS where the service can offer it – Jellyfin serves :8920 alongside for
Prometheus; Navidrome has a single listener, so its scrape is plain too. See
`jellyfin/CLAUDE.md` and `navidrome/CLAUDE.md`.
