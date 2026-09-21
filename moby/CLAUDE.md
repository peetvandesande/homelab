# Moby

CT 108, **192.168.1.27**. Docker container host: engine, compose v2 and
buildx, with the engine's own metrics fronted by nginx on `:9323` and every
container's stdout reaching Loki through the host journal.

It also carries **192.168.1.73 and .74** as extra addresses on `eth0`, because
the stacks that came from the old moby publish their ports on them.

Running here: **nextcloud** (.73), **traefik** (.74) and **xwiki** (behind
traefik), which came from the old moby (192.168.1.25, a machine this repo has
never managed) on 21 September 2026, and **home assistant** (.79), which is
this repo's own.

## Working on this

`root/` mirrors the container filesystem and is the source of truth.
`scripts/bootstrap.sh` creates the container on lenora (run it *on* lenora);
`scripts/deploy.sh` pushes the config; `scripts/verify.sh` checks the intent —
that a container actually runs, that the metrics are TLS and reachable only by
Prometheus, and that the journal lands in Loki.

Deploy **after** `ca/scripts/enrol.sh 192.168.1.27 moby` — the nginx in front
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

7. **The address is outside the Infrastructure range**, like `lexie` at .26.
   The pool is right and the IP is not; both are recorded that way
   deliberately (`../CLAUDE.md`). Don't renumber without grepping
   `prometheus/root/etc/prometheus/prometheus.yml`, `ca/scripts/enrol.sh`,
   `node-exporter/`, `alloy/` and the DNS zones. The same goes double for .73
   and .74, which are in the range `../CLAUDE.md` pencils in for
   Non-Production: they are inherited from the old host, and every compose
   file here names them literally.

## Home Assistant

`/opt/stacks/homeassistant`, pinned to a release rather than `:stable` — the
Nextcloud upgrade below is why. The app binds `127.0.0.1:8123` and the host
nginx serves it on **192.168.1.79:443** off the lab CA; `ca/scripts/enrol.sh`
carries `homeassistant.home` and `.79` as extra SANs on moby's certificate
(they are in `FLEET`, after the shortname).

Three things to know before changing it:

1. **`http:` in `configuration.yaml` is ignored.** Home Assistant 2026.9 keeps
   its HTTP settings in `.storage/http` (`yaml_migration_done: true`) and
   raises a `yaml_still_present_after_migration` repair if the YAML key is
   there at all. A `server_port` or `use_x_forwarded_for` written to YAML is
   silently dropped — the app keeps its stored value and nothing in the log
   says why. Change these in the UI.
2. **nginx sends `X-Forwarded-For`, and that only works because the UI says
   so.** `172.20.0.0/14` is a trusted proxy and `use_x_forwarded_for` is on,
   both under Settings → System → Network, both stored in `.storage/http`.
   Turn either off and every request through nginx gets a bare
   `400 Bad Request`, with one error line in Home Assistant's log and nothing
   at all on the nginx side. `verify.sh` checks the pair still agree.
3. **The websocket is the application.** `Upgrade`/`Connection` come from the
   `map` in `conf.d/websocket-upgrade.conf`, and `proxy_read_timeout` is a
   day, not the default minute. Without those the page loads and then sits
   there unable to connect.

Scraped by Prometheus at `/api/prometheus`, which needs two things that are
easy to miss. The endpoint only exists when `prometheus:` is in
`configuration.yaml` — it is a normal YAML integration, unlike `http:` — and
it needs a long-lived access token, created on the user's profile page. The
token is the only secret in `prometheus/`: it lives in its gitignored
`secrets.env` and `prometheus/scripts/deploy.sh` installs it as
`/etc/prometheus/homeassistant.token`, owned by `prometheus` and mode 0400,
because the unit's `PrivateUsers=true` leaves group membership unmapped.

The container's logs reach Loki like everything else —
`{host="moby", container="homeassistant-homeassistant-1"}`.

## What came from the old moby, and what did not

`scripts/import-stack.sh [--stop] [--up] <stack>` does one stack at a time
from the workstation: it copies `/opt/stacks/<stack>`, finds the stack's
volumes by their `com.docker.compose.project` label, streams each through a
throwaway container (rather than reading `/var/lib/docker/volumes`, which the
engine owns) and compares entry counts on both sides. It refuses to overwrite
an existing stack directory or a non-empty volume here.

The September 2026 move did not use it: 22G of Nextcloud data through the
workstation would have been slow, so the copy ran host-to-host over a
throwaway key, which the script deliberately does not set up. Use the script
for the next one; it is the same commands.

Moved: `nextcloud` (~22G of volumes), `traefik`, `xwiki`, plus
`/var/backups/sylvie`, which the xwiki backup containers write to by absolute
path. The stacks are stopped but intact on .25, and `/etc/network/interfaces`
there has .73 and .74 commented out rather than deleted, so the old host is
still a rollback.

Four things this move left behind:

- **`gotenberg`, `n8n` and `baserow` are no longer proxied.** Traefik's compose
  file joined their networks, which do not exist here, and Traefik refuses to
  start on a missing external network — so those three entries are commented
  out in `/opt/stacks/traefik/docker-compose.yml` (the original is beside it
  as `docker-compose.yml.from-old-moby`). gotenberg is still running on .25
  with no way in. Re-add the line when its stack follows it here.
- **Nextcloud went from 33.0.3 to 34.0.4 on the way.** The compose file tracks
  `nextcloud:stable-fpm-alpine`, so the first start here pulled the current
  stable and ran its upgrade. It completed clean — `needsDbUpgrade` is false
  — but it was not an intended part of the move. Pin the tag if that matters.
- **`.lan` names still do not resolve from this lab's DNS.** Traefik routes by
  `Host:`, and `nextcloud.lan` and the rest were answered by the Pi-hole on
  .78, which stayed behind. `dns/` now has `nextcloud.home` (.73) and
  `traefik.home` (.74), which is not the same name a browser bookmark uses.
- **The old host's static routes did not come across.** Its network config
  sends 172.31.1.1/32, 192.168.254.254/32 and 192.168.204.0/24 via sylvie
  (192.168.1.24). Nothing in these three stacks obviously needs them, so they
  were not copied; if something reaches for a host over there, that is why.

Two more things worth knowing:

- **Published ports answer on .73 and .74, not .25.** Anything on the LAN
  pointing at the old host — bookmarks, the router, another stack's config —
  needs updating.
- **`xwiki-app-backup` has no `restart:` policy**, so it does not come back
  after a reboot. It was not running on the old host either. Left as it is
  rather than quietly fixed.
