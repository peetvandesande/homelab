# Proxmox VE

The web GUI on **lenora, 192.168.1.21:8006**, served off the lab CA.

Named for the service rather than the host, because lenora is the hypervisor
itself and not a container — it is the one entry here that is not a CT.

## Working on this

`root/` mirrors the host filesystem and is the source of truth.
`scripts/deploy.sh` installs the certificate; `scripts/verify.sh` checks the
GUI, the chain and — importantly — that the cluster's own certificate was left
alone.

lenora is enrolled like every other host (`ca/scripts/enrol.sh`), so all this
stack adds is a post-renew hook. There is no separate certificate for it.

## Invariants

1. **Only `pveproxy-ssl.pem` and `pveproxy-ssl.key`.** `pve-ssl.pem` and
   `pve-ssl.key` sit in the same directory, are issued by Proxmox's own
   internal CA, and are what the cluster and API use to talk to themselves.
   Replacing them breaks the node's **API**, not its GUI, and the failure looks
   nothing like a TLS problem. `verify.sh` asserts `pve-ssl.pem` is still
   issued by the PVE Cluster Manager CA precisely so this cannot drift.

2. **No `chown`/`chmod` in the hook.** `/etc/pve` is pmxcfs, which forces
   `root:www-data 0640` on everything written to it and silently ignores
   ownership calls. Adding them would be cargo cult that reads as meaningful.

3. **pveproxy needs a restart, not a reload** — it reads the certificate only
   at start. The GUI is gone for a second or two; running VMs and containers
   are unaffected, because nothing in their data path goes through pveproxy.

4. **`deploy.sh` rolls back on its own.** This is the hypervisor's management
   interface: if pveproxy does not come back on the new certificate, the script
   restores the previous one and restarts, so the GUI is never left down. It
   also refuses to install a certificate and key that do not match, rather than
   restarting into a failure and relying on the rollback.

## Why not Proxmox's built-in ACME

PVE has native ACME with its own renewal timer, and step-ca offers an ACME
provisioner, so this looks like the obvious fit. It does not work here: http-01
requires pistis to resolve `lenora.home`, and pistis uses the router, which
knows nothing about `.home`. The dns-01 route would need Pythia's API key on
lenora and an nginx ACL change on .52.

Reusing the enrolment mechanism costs one hook and no new failure modes, and
lenora was already enrolled for node-exporter. Revisit after the DHCP cutover,
when `.home` resolves and http-01 becomes possible.
