# Homelab

Proxmox VE 9.2 running Debian 13 LXC containers. Containers are the default
unit of deployment — only reach for a VM if something genuinely cannot run in
one.

`pct list` on the host is the source of truth for what exists. Don't trust an
inventory written down here; this file records *conventions*, not state.

## Host

- `lenora`, **192.168.8.21**, web UI on :8006
- 2 x Intel Xeon Gold 6262V, 256GB RAM
- Template: `local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst`

## Router

The LAN is routed by a **GL.iNet GL-BE14000 running OpenWrt**, at
**192.168.8.1**. It replaced an Orange Livebox in October 2026, which is why
this lab is on 192.168.8.0/24 — that is the GL-iNet default range, kept rather
than fought.

- **DHCP pool is .100-.249** (`dhcp.lan.start=100`, `limit=150`). Every lab
  host sits **below .100**, outside the pool, as a static reservation keyed by
  MAC. Keep it that way: a reservation inside the pool races the dynamic range.
- **Reservations are the source of truth for lab addressing.** They live on the
  router (`uci show dhcp`), not in this repo. When you add a container, add the
  reservation first — see the Container defaults below.
- **Three other networks hang off it**, each with its own .100-.249 pool:
  `guest` (192.168.9.0/24) and `iot` (**192.168.10.0/24, VLAN 10**), plus the
  ONT management net on 192.168.11.0/24. VLAN 10 arrives at lenora **tagged on
  the same uplink as the untagged LAN**, so a guest joins it with `tag=10` on
  `vmbr0` and Proxmox builds `vmbr0v10` for it — vmbr0 itself is a traditional
  bridge and must stay that way unless you are ready to bounce every container.
  Nothing in the lab uses `tag=10` today. Two things to know if you add one:
  Proxmox applies a `net` change to the config but **not to the running VM**, so
  the guest needs `echo 1 > /sys/bus/pci/rescan` or a power cycle to see an
  added NIC and keeps a removed one until it restarts; and the guest keeps the
  NetworkManager profile after the NIC goes, which is what lets a restored NIC
  come straight back up.
- The router is not otherwise managed from here.

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
- **IPv4 by DHCP reservation, not static** — pass `ip=dhcp` in `--net0` and
  no `gw=`. The router holds a reservation per MAC, so the address is stable
  and services may still bind to it. **lenora is the one exception**: its
  address is static in `/etc/network/interfaces`. Add the reservation on the
  router *before* starting the container, or it lands in the dynamic pool.
- **IPv6 is SLAAC** — pass `ip6=auto` in `--net0`; omitting it forgoes working
  IPv6. The prefix is delegated by the router and changed with it, so confirm
  the current one rather than trusting a value written down.
- **A DHCP container's `/etc/hosts` maps its own FQDN to `127.0.1.1`**, not to
  its LAN address: Proxmox writes the real address there only when `net0`
  carries a static `ip=` (`PVE/LXC/Setup/Base.pm`). So `<name>.home` resolves
  to loopback *on the container itself*, and anything reaching a host by name
  from inside one talks to itself. Address by IP, as the rest of this repo
  does. `ca/scripts/verify.sh`'s end-to-end issuance check is the one place
  that does not, and it fails for this reason.
- **Leave `--nameserver` unset** so the container inherits the host's resolver,
  unless it is part of the DNS stack itself.
- Always pass `--pool`.

Services bind to specific IPs, and in an LXC with ifupdown
`network-online.target` is reached *before* `eth0` has its address. DHCP widens
that window, so this now applies to every container, not just the DNS stack: if
a service binds to its own address rather than the wildcard, give it a systemd
drop-in that waits for the address — otherwise it will intermittently fail to
bind on cold boot. See `dns/*/etc/systemd/system/*.d/wait-for-address.conf`
for the pattern, including the leading `+` needed to escape unit sandboxing.

## Pools, IDs and addresses

Pool names are **case-sensitive and exact** — `Non-Production`, not
`Non-production`. `pct create --pool Non-production` fails.

| Pool             | Container IDs | IP range              |
|------------------|---------------|-----------------------|
| `Infrastructure` | 100-199       | 192.168.8.50-.59      |
| `Production`     | 300-399       | 192.168.8.60-.69 †    |
| `Non-Production` | 200-299 †     | 192.168.8.70-.79 †    |

† Inferred from the existing pattern, not yet confirmed — Production is using
.60/.61 in practice, and Non-Production is currently empty with no range ever
written down. Confirm before relying on these.

Three things to be aware of:

- **The Infrastructure IP range is nearly gone** (.50-.56 used) while its ID
  range has 93 free slots. The ranges are badly matched in size; widen the IP
  allocation before it bites.
- **`lexie` (CT 100) sits at 192.168.8.24 and `moby` (CT 108) at
  192.168.8.27**, both outside the Infrastructure range they are pooled into.
  Moby additionally answers on .73 and .74 for the stacks it publishes,
  inside the range pencilled in for Non-Production. Existing anomalies —
  don't take them as precedent, and don't "tidy" them without asking.
- **`homeassistant` (VM 302) is at 192.168.8.90**, pooled into Production
  but outside its range, by choice. It is the lab's only VM: Home Assistant
  OS, UEFI (OVMF, Secure Boot keys not enrolled – HAOS will not boot with
  them), with the Sonoff Zigbee dongle passed through as `usb0`. Its address
  is set inside HAOS (`ha network update`), not by Proxmox. Music Assistant
  runs there as a Supervisor app (`d5369777_music_assistant`, host network,
  :8095). It is **on the LAN only** — a second NIC on VLAN 10 was tried in
  October 2026 and removed again, by choice. It serves HTTPS on **:443** off
  the lab CA; `homeassistant/` owns the certificate and its renewal.

## DNS

A three-container PowerDNS stack lives in `dns/` — see `dns/CLAUDE.md` and
`dns/README.md`. What matters at this level:

- **Internal domain is `home.`**, served authoritatively by Pythia
  (192.168.8.52). Reverse zone `8.168.192.in-addr.arpa.`.
- **`ca.peetvandesande.com` is overridden internally** to point at pistis
  (192.168.8.55), because the CA's certificates name it. Split-horizon on a
  DNSSEC-signed domain needs three coordinated pieces — read `dns/CLAUDE.md`
  invariant 5 before touching it.
- **When you add a container, add its A and PTR records** to
  `dns/pythia/var/lib/powerdns/zones/`, bump both serials, and run
  `dns/scripts/deploy.sh`.
- **Clients use Themis (192.168.8.50) as their only resolver.** The DHCP
  cutover happened in October 2026: the router hands out `6,192.168.8.50` on
  the LAN, so every client's queries go through dnsdist and its RPZ filtering.
- **The DNS stack itself stays on the router (192.168.8.1)**, via a dnsmasq
  `dnsinfra` tag on the themis, delphi and pythia reservations. Pointing Delphi
  at Themis would loop, and it could not resolve at boot. The tagged option
  wins over the LAN-wide one because it is more specific — verify that with a
  throwaway `dhclient -1 -sf /bin/true -lf ...` if you ever change it.
- **Pythia is the only authority for `home.`** The router forwards `home.` and
  `8.168.192.in-addr.arpa` to it and no longer names its own DHCP leases into
  the zone. It did both for a while, and odhcpd was injecting AAAA records for
  addresses pythia had never heard of. The cost is that dynamic clients get no
  automatic `.home` name; give anything that needs one a record in `dns/`.
- **No resolver is advertised over IPv6, deliberately.** dnsdist listens on
  IPv4 only (`192.168.8.50:53`), so an IPv6 resolver could only ever be a
  silent bypass of Themis. DHCPv6 is disabled on the LAN and `ra_flags` is
  `none`; addressing is still SLAAC from RA, which is all `ip6=auto` needs.

## Docker

Container workloads that are not worth an LXC run on `moby` (CT 108,
192.168.8.27) — Docker Engine with compose v2, one directory per stack under
`/opt/stacks`. See `moby/CLAUDE.md`. Nextcloud, Traefik and XWiki moved here
from the old moby at 192.168.1.25 (a machine this repo does not manage) in
September 2026; the rest of that host's stacks are still there.

Moby also holds **192.168.8.73 and .74** as extra addresses on `eth0`, one
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

Prometheus (192.168.8.53) is used for **all** monitoring; Grafana
(192.168.8.54) for dashboards and alerting. Loki (192.168.8.56) is the log
store, wired into Grafana as a datasource. Every enrolled host ships its
systemd journal to it via Grafana Alloy (`alloy/`, one directory for all
eleven hosts, like `node-exporter/`); query by `{host="<name>"}` in Grafana.

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
plus lenora. The Home Assistant VM holds a certificate too but is **not
enrolled**: HAOS cannot run step-cli, so it gets one a different way — see
`homeassistant/`.

- **Get a certificate with `ca/scripts/enrol.sh <ip> <name>`.** It installs the
  trust anchors, mints a single-use token on pistis and has the target redeem
  it, so the private key is generated on the host and never moves. Renewal is
  a daily timer authenticated by the certificate itself.
- **Certificates carry IP SANs, and consumers address hosts by IP.** This
  began as a necessity — nothing resolved `.home` — and since the DHCP cutover
  to Themis it is merely a choice: names do now resolve, from any host whose
  resolver is Themis or the router. Moving a consumer to a name is therefore
  possible but is not a comment change: the certificate already carries the
  DNS SAN, but a container still resolves **its own** FQDN to `127.0.1.1` (see
  Container defaults), so anything addressing itself by name breaks. One place
  keeps the IP on purpose rather than by inertia: `homelab-tls-renew`, because
  renewing every certificate in the lab should not depend on DNS being up.
- **Per-service TLS config lives in that service's own top-level directory**
  (`grafana/`, `homeassistant/`, `jellyfin/`, `loki/`, `moby/`, `navidrome/`,
  `prometheus/`), one per container. `node-exporter/` and `alloy/` are the
  exceptions: one service on eleven hosts, so one directory rather than eleven
  copies.
- **The Home Assistant VM is the one host that cannot renew itself.** HAOS has
  no step-cli and no openssl, and `/ssl` is read-only to the core container, so
  a timer on lenora drives it over the guest agent. The key is still generated
  in the VM and never leaves it. See `homeassistant/CLAUDE.md`.
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
