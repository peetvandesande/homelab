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

- **The router's DNS is load-bearing for routing, not just names.** Policy-based
  routing sends traffic into a WireGuard tunnel by *destination IP*, and the
  only thing that fills those ipsets is the router's own dnsmasq, from the
  answers it returns. So a name under a domain policy has to be resolved by the
  router or the tunnel is never used. `dns/` handles this by shunting exactly
  those names back to the tunnel's dnsmasq instance — read `dns/CLAUDE.md`
  invariant 11 before changing anything about who resolves what.
- **DHCP pool is .100-.239** (`dhcp.lan.start=100`, `limit=140`). Every lab
  host sits **below .100**, outside the pool, as a static reservation keyed by
  MAC. Keep it that way: a reservation inside the pool races the dynamic range.
- **`.240-.254` is for client devices that need a stable address** but are not
  lab hosts — today that means anything named in a DNS policy set, which stops
  working the moment the device's address drifts. The pool was narrowed from
  `limit=150` to make room: at .100-.249 this range was *inside* it. Below .100
  stays for servers and services.
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
- **A watchdog keeps the WAN honest.** A PON re-registration can leave the
  Orange session dead one way while the router still holds a valid lease and
  reports the interface up – it cost 88 minutes on 23 October 2026. Nothing in
  the router's own view says so, because the SFP port never loses carrier, so
  `wan-watchdog/` probes out of the WAN device and runs `ifup` when it is up
  but dead. `router/ORANGE.md`, "A dead session behind a live interface".
- **`router/` documents it; it holds no config.** The device's settings live in
  `uci`, written by the GL.iNet web UI, so a mirror here would be a second
  source of truth that always loses. What `router/` records is the part
  `uci show` cannot tell you — which settings the rest of the lab depends on,
  and which ones silently break something. Read `router/CLAUDE.md` before
  changing anything on the device. `router/ORANGE.md` covers the fibre WAN.
- **The router's two WireGuard tunnels go to ruby and jennie**, two OVH servers
  outside the lab. `wireguard/` holds that design, now live. Road-warrior
  clients land on ruby and reach the whole lab from there, the Proxmox SDN
  on 192.168.32.0/21 included – it is a second prefix behind the router and
  has to be named separately from 192.168.8.0/21 everywhere it appears.

## Secrets outside the repo

This repo is public. Besides the gitignored `secrets.env` files, secrets with no
deploy script to template them live outside git in `~/projects/homelab-private/`:
WireGuard keys and filled configs, and the Orange WAN credentials.

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

lenora also **exports `/hddpool/media` over NFS to 192.168.8.0/24** for hosts
that are not containers on it; `proxmox/root/etc/exports` owns that. It is not
how containers here get the data — an unprivileged LXC cannot mount NFS.

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
- **IPv6 is SLAAC, and `--net0` should carry no `ip6=` at all.** Omitting it
  does *not* forgo IPv6, which this file claimed until 25 October 2026:
  `accept_ra` is on by default, so the kernel takes the ULA and the GUA from
  the router's RA with no help from ifupdown. prometheus and grafana had always
  run that way, which is what disproved it. `ip6=auto` is actively harmful —
  see below. The prefix is delegated by the router and changed with it, so
  confirm the current one rather than trusting a value written down.
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

**Never put `ip6=auto` back.** Proxmox turns it into `iface eth0 inet6 auto`,
and Debian's ifupdown implements that by running `dhclient -6` as well as
accepting RAs. The router runs **no DHCPv6** by design (`ra_flags none`,
DHCPv6 disabled), so those solicits are never answered and
`networking.service` never leaves `activating`. Addressing is unaffected — the
addresses come from the RA — which is exactly what makes it hard to notice.

It was removed from all eleven containers on 25 October 2026. Each is now
`iface eth0 inet dhcp` alone, holds its ULA and GUA, and runs one `dhclient`
for IPv4 and none for IPv6. Dropping it preserves the hwaddr, which matters
more than the rest of the change: the DHCP reservation, the SLAAC ULA in every
certificate, and the router's by-MAC DNS exemptions for delphi and hermes all
key off it.

The reason it survived so long is worth keeping even though the cause is gone.
`networking.service` has `TimeoutStartSec=infinity`, so a wedged one **never
fails** — and `systemd-unit-failed` in `grafana/` only sees units that fail. A
unit stuck in `activating` forever is invisible to this lab's monitoring in a
way a crashed one is not, and anything keying off `is-system-running` reads a
healthy container as still booting. Nothing alerts on that today.

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

- **The Infrastructure IP range is nearly gone** (.50-.57 used) while its ID
  range has 93 free slots. The ranges are badly matched in size; widen the IP
  allocation before it bites.
- **`lexie` (CT 100) sits at 192.168.8.24 and `moby` (CT 108) at
  192.168.8.27**, both outside the Infrastructure range they are pooled into.
  Moby additionally answers on .73 and .74 for the stacks it publishes,
  inside the range pencilled in for Non-Production. Existing anomalies —
  don't take them as precedent, and don't "tidy" them without asking.

  **Lexie is outside `FLEET`**, so it holds no certificate, is not scraped, and
  `fleet/` and `apt/` never reach it. It had `proc-fs-nfsd.mount` and
  `run-rpc_pipefs.mount` failed — an unprivileged LXC cannot mount either —
  which nothing in the lab could see, for the same reason. Both were masked by
  hand on 25 October 2026. They must **not** go in `fleet/masked-units`: that
  file masks on every enrolled host, and both units are *active and required on
  lenora*, which exports `/hddpool/media` over NFS. Nothing reapplies the mask
  if lexie is rebuilt.

  **Lexie also runs the alert responder**, a dedicated `responder` account that
  investigates alerts read-only. `responder/CLAUDE.md`.
- **`homeassistant` (VM 302) is at 192.168.8.90**, pooled into Production
  but outside its range, by choice. It is one of two VMs, with `hermes`:
  Home Assistant OS, UEFI (OVMF, Secure Boot keys not enrolled – HAOS will
  not boot with them), with the Sonoff Zigbee dongle passed through as `usb0`. Its address
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
- **`mail.peetvandesande.com` is overridden internally too**, to ruby's wg0
  addresses 192.168.204.254 and `fd33:5692:1834:204::254`, because ruby serves
  mail only over the tunnel — and submission (587/465) only on wg0, so the
  dummy0 addresses this named until 23 October 2026 fetch mail and refuse to
  send it. Same three pieces, same invariant 5. An AAAA here must answer over
  the tunnel or it hangs clients; check before changing it.
  **`ruby.peetvandesande.com`** is overridden to ruby's dummy0 addresses
  192.168.254.254 and `fd33:5692:1834:254::254`, so the LAN reaches ruby's
  nginx admin pages over the tunnel, where they are allowed.
- **When you add a container, add its A and PTR records** to
  `dns/pythia/var/lib/powerdns/zones/`, bump both serials, and run
  `dns/scripts/deploy.sh`.
- **Clients use Themis.** `dhcp.lan.dhcp_option` is `6,192.168.8.50`, with
  `15,home`. The first attempt at this, in early October 2026, was reverted on
  9 October because sending clients straight to Themis stopped the router
  seeing the queries its domain-based VPN routing depends on; the shunt in
  `dns/CLAUDE.md` invariant 11 fixes that, and the cutover was redone on
  11 October 2026 (`dhcp.bak-2026-10-11-themis-cutover` on the router).
- **The DNS stack itself stays on the router (192.168.8.1)**, via a dnsmasq
  `dnsinfra` tag on the themis, delphi and pythia reservations. Pointing Delphi
  at Themis would loop, and it could not resolve at boot. The tagged option
  wins over the LAN-wide one because it is more specific — verify that with a
  throwaway `dhclient -1 -sf /bin/true -lf ...` if you ever change it. It is
  the same value as the LAN-wide option today, which makes it look redundant;
  it is not, and it has to stay when the LAN moves back to Themis.
- **Two router settings must stay off**, both of which would break the stack:
  `noresolv` plus `server=192.168.8.50` on the main dnsmasq (Themis forwards
  the VPN policy domains *to* the router, so that is a loop), and the force-DNS
  redirect, which would hijack clients' queries to `.50` back to the router.
- **Outgoing DNS that is not Themis is rejected at the router** — :53 and :853
  from every LAN zone, and the well-known public resolvers on :443 — so DoT,
  DoQ, DoH and hard-coded resolvers all fail fast and clients fall back to
  Themis. Delphi and hermes are exempt from the :53 rule **by MAC**, because
  both recurse themselves; rebuild either with a new MAC and its recursion
  stops. `router/CLAUDE.md` invariant 10. The names of DoH resolvers are blocked
  on Delphi as well (`doh` feed, default set); Themis answers the Firefox
  canary NXDOMAIN.
- **Pythia is the only authority for `home.`** The router forwards `home.` and
  `8.168.192.in-addr.arpa` to it and no longer names its own DHCP leases into
  the zone. It did both for a while, and odhcpd was injecting AAAA records for
  addresses pythia had never heard of. The cost is that dynamic clients get no
  automatic `.home` name; give anything that needs one a record in `dns/`.
- **Themis is advertised over IPv6 too**, since the IPv6 rollout. dnsdist
  listens on its ULA as well as `192.168.8.50` for :53, :853 and :443, and the
  RA carries that ULA as RDNSS (`dhcp.lan.ra_dns='1'` plus `dhcp.lan.dns`).
  This was IPv4-only until then, on the grounds that an IPv6 resolver could
  only be a bypass of Themis — the bypass was the *router*, not the family, and
  the fix was to advertise Themis rather than nothing. The router's outgoing-DNS
  rejects were family-agnostic from the day they were written, so there was no
  hole to close. **Both router options go together**: `ra_dns='1'` with
  `dhcp.lan.dns` empty advertises the router itself —
  `router/CLAUDE.md` invariant 12. DHCPv6 stays disabled and `ra_flags` stays
  `none`; addressing is SLAAC from RA, which is all `ip6=auto` needs.

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

## Mail

`hermes` (VM 109, 192.168.8.57) runs **mailcow** for the Proxmox labs, so
their made-up customers have mailboxes to read in SOGo at
`https://hermes.home/SOGo/`. It is a VM because mailcow does not support LXC.
It is cut down to Rspamd plus webmail – no ClamAV, Olefy, full-text search or
ACME – and the lab CA supplies its certificate.

Lab hosts on 192.168.32.0/21 (and lenora, for SDN zones that SNAT) relay
through `192.168.8.57:25` without authentication. **Nothing leaves by
default**: mail for a domain hermes does not host bounces. A domain that really
must go out is routed via ruby with a mailcow transport map. See
`hermes/CLAUDE.md`.

## Monitoring

Prometheus (192.168.8.53) is used for **all** monitoring; Grafana
(192.168.8.54) for dashboards and alerting. Three dashboards are provisioned
from `grafana/` — `homelab-dns`, `homelab-fleet` and `homelab-router` — with
the alert rules in groups `dns`, `fleet` and one per concern beside them. The
router and the ONT in it cannot run node-exporter, so lenora collects both into
its textfile collector – `router-metrics/`. Alerts are delivered to
**Home Assistant**, which pushes them to the phone (critical alerts break
through Do Not Disturb) — `grafana/CLAUDE.md`, "Delivery". That path runs over
the home connection, so it cannot report a home outage; a heartbeat rule pings
**Healthchecks.io** every 5 minutes instead, and that alerts from outside when
the pings stop – `grafana/CLAUDE.md`, "Heartbeat". ruby and jennie probe
each other's public side with blackbox exporters, scraped over the tunnels –
`outside/`; a blackbox exporter on .53 probes the internet, the tunnels, DNS
end to end and every lab certificate – `prometheus/CLAUDE.md` invariant 7. Loki (192.168.8.56) is the log
store, wired into Grafana as a datasource. Every enrolled host ships its
systemd journal to it via Grafana Alloy (`alloy/`, one directory for all
twelve hosts, like `node-exporter/`); query by `{host="<name>"}` in Grafana.
The router cannot run Alloy, so it sends syslog to Loki's own Alloy over UDP
instead, as `{host="router"}` – `loki/CLAUDE.md`, `router/README.md` "Logs".

**Prometheus config now lives in `prometheus/`, not on the host.** Editing
`/etc/prometheus/prometheus.yml` on .53 directly will be overwritten by the
next deploy.

**Fleet-wide host hygiene lives in `fleet/`** — units masked on every host, and
anything else that belongs to no single service. `fleet/scripts/verify.sh`
answers "is the fleet clean?" and asserts no host has a failed unit;
`fleet/scripts/deploy.sh <ip>` reapplies it to one host after a rebuild. It
reads the host list from `ca/scripts/enrol.sh` rather than keeping a fourth
copy. Today it masks `openipmi.service`, which was the fleet's only failed unit
and made the `systemd-unit-failed` alert useless — see `fleet/CLAUDE.md`.

**Automatic security patching lives in `apt/`** — unattended-upgrades on all
twelve enrolled hosts, restricted to the Debian security origin, which is what
keeps Proxmox, Docker and mailcow upgrades a manual act. Nothing is restarted
or rebooted unattended; that gap is published as a metric instead. There is
deliberately **no apt cache or proxy**: the bandwidth it would save is a
rounding error on a fibre line, and the traffic that is actually large is
Docker image pulls, which an apt proxy does not touch. `apt/CLAUDE.md`.

Jobs that are not services publish state through node-exporter's **textfile
collector**, enabled fleet-wide: drop a `.prom` file into
`/var/lib/node_exporter/textfile` and it is scraped with the host's own labels.
`dns/`'s `vpn-domain-sync` is the first user.

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
off the lab's own CA (`ca/`). Twelve hosts are enrolled — all ten containers,
the hermes VM and lenora. The Home Assistant VM holds a certificate too but is
**not enrolled**: HAOS cannot run step-cli, so it gets one a different way — see
`homeassistant/`.

- **Get a certificate with `ca/scripts/enrol.sh <ip> <name>`.** It installs the
  trust anchors, mints a single-use token on pistis and has the target redeem
  it, so the private key is generated on the host and never moves. Renewal is
  a daily timer authenticated by the certificate itself.
- **Consumers address hosts by name, and certificates carry IP SANs for both
  families.** Addressing by IP began as a necessity — nothing resolved `.home`
  — and the IPv6 rollout is what finally retired it: Prometheus targets,
  Grafana's two datasources and Alloy's push URL are `<name>.home`, verified
  against the DNS SAN the certificates already carried. `enrol.sh` also adds
  each host's ULA as an IP SAN, discovered on the host rather than tabulated.

  A container still resolves **its own** FQDN to `127.0.1.1` (see Container
  defaults), and that turned out to be harmless where it happens — Loki and
  node-exporter bind the wildcard, so they answer on loopback, and TLS verifies
  on the name rather than on whichever address it resolved to. It would bite a
  service bound to one specific non-loopback address.

  One place keeps the IP on purpose: `homelab-tls-renew`, because renewing
  every certificate in the lab should not depend on DNS being up.
- **Per-service TLS config lives in that service's own top-level directory**
  (`grafana/`, `hermes/`, `homeassistant/`, `jellyfin/`, `loki/`, `moby/`,
  `navidrome/`, `prometheus/`), one per container or VM. `node-exporter/` and
  `alloy/` are the exceptions: one service on twelve hosts, so one directory
  rather than twelve copies.
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
Queries over all three transports go through one rule chain, so filtering and
the VPN shunt apply to them identically.

The Proxmox web GUI (lenora:8006) is on the CA too — see `proxmox/CLAUDE.md`.
Only `pveproxy-ssl.*` was replaced; `pve-ssl.*` stays on Proxmox's internal CA
because the cluster API depends on it.

Still plain HTTP, deliberately: the media UIs. Streaming is LAN-only, so
Jellyfin's :8096 and Navidrome's :4533 are unencrypted. Their metrics scrapes
stay TLS where the service can offer it – Jellyfin serves :8920 alongside for
Prometheus; Navidrome has a single listener, so its scrape is plain too. See
`jellyfin/CLAUDE.md` and `navidrome/CLAUDE.md`.
