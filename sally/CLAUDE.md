# sally

Proxmox Backup Server on bare metal, `sally.home`. The backup destination for
the lab; `infra/README.md` holds the decisions, including that it stays out of
reach of anything automated that could destroy backups.

`scripts/deploy.sh` puts the proxy on the lab CA and `scripts/verify.sh` checks
it. `scripts/backups.sh` sets up retention, the token and the job. `root/`
mirrors the files this repo owns on the host, and `lenora/` those on lenora.

## How a night goes

| When | What |
|---|---|
| 01:00 UTC | The BIOS powers sally on (Power Management, Auto On Time). Its clock is UTC |
| 03:30 local | lenora's job `sally-nightly` backs up every guest but the 9xxx lab VMs |
| 04:30, 04:45 | Prune (7 daily, 4 weekly, 6 monthly), then garbage collection |
| Sun 05:00 | Verify |
| 2nd Sun 05:05 | Scrub |
| After 05:15 | Power-off, once nothing has been busy for 20 minutes |

Keep it on: log in, or `touch /run/sally-hold`. `scripts/power-schedule.sh off`
stops the power-off altogether.

## Access

Root SSH accepts only `~/.ssh/sally`, whose passphrase is in Bitwarden, so nothing
automated can reach this host. To run a script here, load the key briefly:
`ssh-add -t 15m ~/.ssh/sally`. While it is loaded any process on that machine can
use it, Claude sessions included, so do not leave it loaded.

## Restoring

In the Proxmox UI: storage `sally` on lenora, Backups, pick one, Restore. By
command: `pvesm list sally --vmid <id>`, then `pct restore <id> <volume>
--storage ssdpool` for a container or `qmrestore <volume> <id>` for a VM. sally
must be on: power it on, then `touch /run/sally-hold`.

If lenora was rebuilt: run `infra/scripts/vault.py pull` on the workstation,
which restores the encryption key to the cache, then `scripts/backups.sh`, which
reconnects lenora using that key and makes a new token.

`homelab-backup-restore-test` on lenora proves this monthly with pythia.

## Invariants

1. **Not in `FLEET`.** Every script that reads `FLEET` in `ca/scripts/enrol.sh`
   acts on the whole list, and `responder/scripts/hosts.sh` would give the alert
   responder an account here. Enrol it by hand, as `ca/scripts/enrol.sh <ip>
   sally`; `--all` will not reach it.

2. **Clients must not pin the certificate's fingerprint.** Certificates here
   last 30 days and renew daily, so a pinned fingerprint breaks backups at the
   next renewal. Leave `fingerprint` unset on the client; a host that trusts the
   lab root verifies sally by chain.

3. **`proxy.pem` and `proxy.key` are `root:backup 0640`.** The proxy runs as
   `backup`. The renewal hook sets this; `verify.sh` asserts it.

4. **Reload, not restart, on renewal.** The hook runs daily and a restart
   could interrupt a backup in progress.

5. **lenora's token cannot delete.** It has the `DatastoreBackup` role, so prune
   jobs run on sally. Do not give it more to make something convenient.

6. **Never let `backups.sh` make a new encryption key while backups exist.** It
   reuses the key in the cache and stops if lenora holds a different one. The key
   is `pbs/sally-encryption-key` in Bitwarden.

7. **A missed backup is detected on lenora, not here.** sally is off for most
   of the day, so its `sally` Prometheus job is outside the target-down rules.
   `homelab-backup-hook` publishes each guest's last good backup, and a guest not
   in `GUESTS` in `backups.sh` reads as never backed up, which alerts.
