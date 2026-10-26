# Proxmox VE

The web GUI on **lenora, 192.168.8.21:8006**, served off the lab CA, plus the
host's **NFS export** of `/hddpool/media`, and its **time source**.

Named for the service rather than the host, because lenora is the hypervisor
itself and not a container — it is the one entry here that is not a CT.

## Working on this

`root/` mirrors the host filesystem and is the source of truth.
`scripts/deploy.sh` installs the certificate; `scripts/verify.sh` checks the
GUI, the chain and — importantly — that the cluster's own certificate was left
alone.

lenora is enrolled like every other host (`ca/scripts/enrol.sh`), so all this
stack adds is a post-renew hook. There is no separate certificate for it.

## The NFS export

`root/etc/exports` publishes `/hddpool/media` to **192.168.8.0/24**, read-write
with `all_squash` to `nobody:nogroup` (65534). `deploy.sh` reapplies it with
`exportfs -ra`, which re-reads the export set without restarting `nfs-server`
or disturbing existing mounts.

Two things about it:

- **It named the old `192.168.1.0/24` until 11 October 2026.** The LAN moved to
  192.168.8.0/24 when the GL.iNet router replaced the Livebox, and the export
  was never updated, so nothing on the current LAN could mount it — and the
  failure was an access denial on the client, nothing visible on lenora.
  `verify.sh` now asserts the range, so this cannot rot silently again. The
  host's previous file is `/etc/exports.bak-2026-10-11-lan8`.
- **Containers on lenora do not use it.** An unprivileged LXC cannot mount NFS,
  so they take `/hddpool/media` through the `mp0` bind mount. The export exists
  for machines that are not containers on this host, which is why a whole-`/24`
  grant with everything squashed to nobody is an acceptable granularity.

## Time

`root/etc/chrony/chrony.conf` is Debian's default with the pool swapped for
`server 192.168.8.1`, the router's chronyd (`router/README.md`). It matters more
here than anywhere: containers have no clock of their own, so every one of them
runs on lenora's. By IP, so time does not depend on DNS. `verify.sh` asserts the
router is the only source. The host's previous file is
`/etc/chrony/chrony.conf.bak-2026-10-11-router-ntp`.

## The GPU is not the host's

The Quadro P2200 is bound to `vfio-pci` for passthrough to uc1-lab
(`/etc/modprobe.d/uc1-vfio.conf`) and `nvidia` is blacklisted, so lenora never
loads the driver. `nvidia-devnodes.service` and `nvidia-persistenced.service`,
shipped by the driver package, therefore failed on every boot and kept
`systemd-unit-failed` firing. `deploy.sh` masks both and resets them, as of
26 October 2026. They stay out of `fleet/masked-units`, which is for units
masked on the whole fleet. If the card is ever handed back to the host, unmask
them by hand and drop the stanza.

They were not the package's units but hand-written ones in
`/etc/systemd/system` from 9 September, from when the host used the card
(`nvidia-devnodes` ran `nvidia-modprobe -c 0 -u` before `pve-guests`). `mask`
refuses to replace a real file, so those were disabled and deleted first; the
originals are in `/root/nvidia-units.bak-2026-10-26/` on lenora. A rebuilt host
has neither file, so the stanza's plain `mask` is enough.

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
lenora was already enrolled for node-exporter. The DHCP cutover has since
happened, so `.home` resolves and http-01 is possible in principle — but note
pistis is one of the three hosts deliberately left on the router, and the
router resolves `home.` only by forwarding to Pythia. Worth revisiting, not
free.
