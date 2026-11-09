# sally

Proxmox Backup Server on bare metal, `sally.home`. The backup destination for
the lab; `infra/README.md` holds the decisions, including that it stays out of
reach of anything automated that could destroy backups.

`scripts/deploy.sh` puts the proxy on the lab CA and `scripts/verify.sh` checks
it. `root/` mirrors the files this repo owns on the host.

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
