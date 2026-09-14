# alloy

Grafana Alloy shipping the systemd journal to Loki (192.168.1.56:3100) from
**all ten enrolled hosts** — the nine containers plus lenora — and serving its
own metrics over TLS on `:12345`.

One directory rather than ten, for the same reason as `node-exporter/`: one
service replicated, not a per-container concern.

## Working on this

`root/` mirrors the host filesystem and is the source of truth; the same four
files go to every host. `scripts/deploy.sh` installs the pinned package where
missing, pushes them and proves each host is serving TLS *and* landing lines
in Loki. `scripts/verify.sh` checks all ten. `scripts/deploy.sh <ip>` does one
host, for bringing a new container in.

Hosts must be enrolled first (`ca/scripts/enrol.sh`) — the listener and the
push both need the certificate material. Loki must be up, or deploy refuses.

## Invariants

1. **The journal is the only source.** No host runs rsyslog and nothing in the
   lab writes its own log files that matter; adding a `loki.source.file` is a
   per-service decision, not a fleet one. `path` stays empty so sd_journal
   opens whatever exists — lenora's journal is `Storage=volatile`
   (`/run/log/journal`), the containers' are persistent. Do not "fix" lenora's
   journald to make it match: Loki is now its persistent log.

2. **Four labels: `host`, `unit`, `identifier`, `level`.** All bounded. Every
   label value is a Loki stream; promote a PID or a message field and the
   index explodes. Filter on content with LogQL instead.

3. **`alloy` needs three groups: `systemd-journal`, `adm`, `tlscert`.** The
   first two read the journal, the third reads the key. Missing the journal
   groups is silent — Alloy is healthy, `/-/ready` is 200, and nothing ships.
   `verify.sh` therefore asks Loki, not Alloy, whether a host is logging.

4. **The listen address is a flag in `/etc/default/alloy`; TLS is in the
   config.** Alloy has no config key for the address. The package default is
   loopback, so the file is replaced wholesale — it has no per-host content,
   which is why this is not an `ExecStart` override like node-exporter's.

5. **The package is pinned and held** (`ALLOY_VER` in `deploy.sh`,
   `apt-mark hold`), like Loki. The config language moves between minors;
   bump the pin and the config together and let `alloy validate` on the
   deploy prove the pair. Deploying adds the Grafana apt repo to the eight
   hosts that did not have it, lenora included.

6. **`max_age` is 166h, just under Loki's 168h `reject_old_samples_max_age`.**
   A fresh host backfills up to a week; anything older is rejected with a 400
   that Alloy does not retry. Keep the two in step if either changes.

## Gotcha

Certificate renewal is a restart (`post-renew.d/15-alloy`), not the HUP
reload — the listener reads the certificate once. The journal cursor lives in
`/var/lib/alloy/data`, so a restart re-sends nothing and loses nothing.
