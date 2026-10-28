# Moby

CT 108, **192.168.8.27**. Docker container host: engine, compose v2 and
buildx, with the engine's own metrics fronted by nginx on `:9323` and every
container's stdout reaching Loki through the host journal.

It also carries **192.168.8.73 and .74** as extra addresses on `eth0`, because
the stacks that came from the old moby publish their ports on them.

Running here: **nextcloud** (.73), **traefik** (.74) and **xwiki** (behind
traefik), which came from the old moby (192.168.1.25, since retired) on
21 September 2026 and are host-owned; and **n8n**, the one
stack this repo owns, behind the host nginx on .27 as `n8n.peetvandesande.com`
– and **n8n-sogode**, the same stack for Sogode business use as `n8n.sogode.com`
(built 28 October 2026).

## Working on this

`root/` mirrors the container filesystem and is the source of truth.
`scripts/bootstrap.sh` creates the container on lenora (run it *on* lenora);
`scripts/deploy.sh` pushes the config; `scripts/verify.sh` checks the intent —
that a container actually runs, that the metrics are TLS and reachable only by
Prometheus, and that the journal lands in Loki.

Deploy **after** `ca/scripts/enrol.sh 192.168.8.27 moby` — the nginx in front
of the metrics names the certificate and will not start without it.

## Invariants

1. **`keyctl=1` is not optional.** Docker is the only thing in this lab that
   needs more than the fleet's `nesting=1`: containerd makes kernel keyring
   calls that fail in an unprivileged LXC without it, and the failures surface
   as permission errors inside images rather than as anything naming keyctl.
   `bootstrap.sh` asserts it on every run, not just at create, because a
   `pct set --features` only takes effect on a restart.

2. **Container workloads are Docker's, not Proxmox's.** A stack gets a
   directory under `/opt/stacks/<name>` with its own `compose.yaml` and named
   volumes under `/var/lib/docker`; it does not get its own LXC. A stack this
   repo owns lives in `root/opt/stacks/` and `deploy.sh` converges it; the
   three that came from the old moby are host-owned, carry their own secrets,
   and nothing here starts or stops them. The rootfs is
   80G on `ssdpool` and holds images, volumes and build cache alike — grow the
   rootfs rather than bind-mounting bulk storage, unless a stack genuinely
   consumes the media library.

3. **The engine logs through journald, and that is what puts container output
   in Loki.** `daemon.json` sets `log-driver: journald` with the container
   name as the tag; `alloy/` promotes the journal's `CONTAINER_NAME` field to
   a `container` label. Switch a stack to `json-file` and its logs vanish from
   Grafana while `docker logs` keeps working — which is exactly the sort of
   gap nobody notices.

4. **The engine cannot serve TLS, so nginx does.** dockerd binds
   `127.0.0.1:9324` and nginx fronts it on `:9323`, allowing only .53. The
   pattern, and the reasoning, is the same as the three PowerDNS webservers.

5. **`deploy.sh` restarts the engine rather than reloading it.**
   `log-driver` and `metrics-addr` are read at daemon start; SIGHUP does not
   pick them up. `live-restore: true` keeps running containers alive across
   the restart, so this is safe once stacks are on here — but it is only safe
   because of that setting. Do not drop it.

6. **The extra addresses are a unit, not interface config.**
   `/etc/homelab-extra-addresses` lists them and
   `homelab-extra-addresses.service` applies them, because `pct` carries one
   address per interface and Proxmox rewrites the container's
   `/etc/network/interfaces` on every start. `docker.service` **Requires** that
   unit: a container publishing on an address that is not there yet does not
   wait, it fails the bind and exits, and compose reports it as a crash that
   names neither the address nor the reason. The unit is `RemainAfterExit`, so
   `systemctl start` on an already-active unit does nothing — use `restart` to
   reapply.

7. **The address is outside the Infrastructure range**, like `lexie` at .24.
   The pool is right and the IP is not; both are recorded that way
   deliberately (`../CLAUDE.md`). Don't renumber without grepping
   `prometheus/root/etc/prometheus/prometheus.yml`, `ca/scripts/enrol.sh`,
   `node-exporter/`, `alloy/` and the DNS zones. The same goes double for .73
   and .74, which are in the range `../CLAUDE.md` pencils in for
   Non-Production: they are inherited from the old host, and every compose
   file here names them literally.

8. **nginx binds 192.168.8.27:80/443, not the IPv4 wildcard.** Docker holds
   those ports on .73 and .74, and Linux will not let a wildcard listener share
   a port with specific ones – so nginx names .27, and has a wait-for-address
   drop-in (`nginx.service.d`) because a specific address can lose the
   cold-boot race. If it does, nginx fails whole and the engine metrics on
   9323 go with it. IPv6 is `[::]`, which nginx makes v6-only, so it never
   collides. n8n (production) is the `default_server` on .27:443, so `moby.home` answers
   with it.

## n8n

`root/opt/stacks/n8n/compose.yaml`: n8n pinned to a release, plus Postgres,
published on `127.0.0.1:5678` only. `etc/nginx/sites-available/n8n.conf`
terminates TLS with moby's lab certificate, which carries `n8n.home` and
`n8n.peetvandesande.com` as SANs (`FLEET` in `ca/scripts/enrol.sh`).

- **One URL.** `WEBHOOK_URL` is the public name; on the LAN it is
  split-horizon to moby, off it ruby proxies to moby's nginx over wg1
  (`ruby/`, installed on ruby with `scripts/install-ruby.sh`). Through ruby
  only webhooks, forms and their assets are public; the editor and APIs are
  limited to `snippets/home-lan-allow.conf`. On the LAN everything is open,
  and VPN clients count as the LAN: the tunnel's DNS gives them moby too.
- **One proxy hop, both ways.** moby's nginx trusts `X-Forwarded-For` from
  ruby's ranges (`real_ip`) and passes the real client on, so
  `N8N_PROXY_HOPS=1` is right whether a request came via ruby or not.
- **`.env` is the secrets, generated once by `deploy.sh`.**
  `N8N_ENCRYPTION_KEY` encrypts every stored credential; regenerating it
  orphans them. It and the `n8n_db` volume are one backup – and there is no
  backup yet.
- **Instance AI's sandbox service** runs in the same stack: `sandbox-api`,
  `sandbox-runner-1` and a one-shot `sandbox-certs`, pinned together to one
  release (n8n's own `get-n8n-compose.yml`). n8n reaches it as
  `http://sandbox-api:8080` on the stack's network and nothing of it is
  published. The runner is **privileged Docker-in-Docker**, root-equivalent
  on moby – which works in this unprivileged LXC with `nesting` and
  `keyctl`. Its three secrets are generated into `.env` once. Bump its tag
  with n8n's, following that file.
- **Task runners and SearXNG** complete that reference stack. Code nodes run
  in the `runners` container (same tag as n8n – bump them together), which
  dials n8n's broker on 5679 inside the stack; SearXNG is Instance AI's web
  search, internal only, with `searxng-settings.yml` enabling its JSON API.
- **Upgrades are a tag bump** in `compose.yaml` and a deploy. n8n migrates its
  database on start; read the release notes first.
- **`/metrics`** goes through nginx, allowed to Prometheus by both its
  addresses; the `n8n` job scrapes `n8n.home:443`.
- **Mail** goes out as `n8n@peetvandesande.com` through ruby's submission
  port, as Forgejo's does. The password is in
  `homelab-private/n8n/secrets.env` (`SMTP_PASSWD=`) and the mailbox; change
  both, then `deploy.sh`, which rewrites it into `.env` every time.

## n8n-sogode

`root/opt/stacks/n8n-sogode/`: the same stack again for **Sogode business
use**, at `https://n8n.sogode.com/` – its own Postgres, encryption key,
sandbox service, task runners and SearXNG, published on `127.0.0.1:5680`
behind `n8n-sogode.conf`. Keep the two compose files in step: they differ
only in the name, port, URLs and mailbox, and `deploy.sh` converges both with
one function.

- **The name works from three sides.** Publicly an A/AAAA to ruby (not a
  CNAME – the name also carries its mail domain's MX and SPF), whose vhost
  `ruby/…/n8n.sogode.com` is installed with `scripts/install-ruby-sogode.sh`;
  in the lab a split-horizon zone on Pythia, with a forward and an `addNTA`
  on Delphi because sogode.com is DNSSEC-signed; on the VPN an `n8n` record
  in ruby's and jennie's own sogode.com zone
  (`wireguard/install-public-overrides.sh`). moby's certificate carries it.
- **Mail is `n8n@n8n.sogode.com`, a mailbox on ruby**, not Office 365, which
  keeps sogode.com itself. `n8n.sogode.com` is its own mail domain: MX to
  ruby, `v=spf1 mx -all`, DKIM selector `mail` signed by ruby, and no DMARC
  record of its own, so sogode.com's `p=reject` applies – which the SPF and
  DKIM alignment satisfy. `shared/ruby-mail-domain.sh n8n.sogode.com
  n8n@n8n.sogode.com` on ruby checks all of it and makes the DKIM key. The
  password is in `homelab-private/n8n-sogode/secrets.env`.
- **Monitored and alerted** like production: the `n8n-sogode` job is in the
  service target-down alert. No backup, as for production.

## Home Assistant is gone

It ran here as `/opt/stacks/homeassistant` on **192.168.8.79**, behind the
host nginx, from September 2026 until 24 September 2026, when it was removed
in favour of a dedicated VM. Deleted with it: the stack and its config volume,
the nginx site and the `map` in `conf.d/websocket-upgrade.conf`, .79 from
`root/etc/homelab-extra-addresses` and from moby's SANs in
`ca/scripts/enrol.sh`, the `homeassistant` Prometheus job and its token, and
the `homeassistant.home` A and PTR records.

Why it moved: the compose file claimed mDNS/SSDP discovery "does not cross the
LXC bridge". That is wrong — `vmbr0` is a plain bridge and a `tcpdump` on
moby's `eth0` sees mDNS on both v4 and v6. What actually blocked discovery was
Docker's bridge network: HA sat in a NAT'd namespace whose only route pointed
at the Docker bridge, so it neither sent to nor received from `224.0.0.251`.
`network_mode: host` would have fixed it in the LXC. The VM was chosen anyway.

Removed with it, in the restart on 24 September 2026: **`mp0`**, which
mounted `/hddpool/media` at `/var/media` read-only for the media browser, and
**`dev0`**, the Sonoff Zigbee 3.0 USB Dongle Plus V2 on `/dev/ttyUSB0`. CT 108
now has neither a mountpoint nor a passed-through device. The dongle is
`10c4:ea60` on lenora, stable as
`/dev/serial/by-id/usb-Itead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_4473157d6d32f1118879f330984367d3-if00-port0`
— a VM takes it as a `qm set --usb0 host=10c4:ea60` passthrough, not a `dev`
entry.

## What came from the old moby

Nextcloud (~22G of volumes), Traefik and XWiki moved here on 21 September 2026,
host to host, along with `/var/backups/sylvie`, which the xwiki backup
containers write to by absolute path. The old moby (192.168.1.25) has since
been retired, so there is no rollback and nothing more to fetch: gotenberg,
baserow and the old n8n went with it (n8n was rebuilt here fresh).

What the move left behind, still true:

- **Nextcloud went from 33.0.3 to 34.0.4 on the way.** The compose file tracks
  `nextcloud:stable-fpm-alpine`, so the first start here pulled the current
  stable and ran its upgrade. It completed clean, but it was not an intended
  part of the move. Pin the tag if that matters.
- **`.lan` names do not resolve from this lab's DNS.** Traefik routes by
  `Host:`, and `nextcloud.lan` and the rest were answered by a Pi-hole that
  went with the old LAN. `dns/` has `nextcloud.home` (.73) and `traefik.home`
  (.74), which is not the same name a browser bookmark uses.
- **The old host's static routes did not come across** (172.31.1.1/32,
  192.168.254.254/32 and 192.168.204.0/24 via sylvie). The router routes
  those now.
- **`xwiki-app-backup` has no `restart:` policy**, so it does not come back
  after a reboot. Left as it is rather than quietly fixed.
