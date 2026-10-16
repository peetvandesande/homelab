# wireguard

Site-to-site WireGuard between the lab and two OVH servers outside it:
**ruby** (mail, DNS, the road-warrior clients on wg0) and **jennie** (the VPN's
internet exit). The home end is the router's `wgclient1` (wg1, to ruby) and
`wgclient2` (wg3, to jennie) – `router/README.md` covers how the router routes
into them.

Unlike the other top-level directories this is not a container filesystem and
has no `deploy.sh`. It was a hand-run rollout, now live:

- `README.md` – the design and why: explanation only, no runbook steps
- `TASKS.md` – the rollout's steps in order, with commands, the open
  follow-ups, and (as appendices) the original task notes and rollback.
  Status was last recorded on 2026-10-16; check the hosts before trusting it.

## Secrets are not in this repo

The repo is public. Every private key and PSK in `ruby/`, `jennie/` and `home/`
is a `<placeholder>`. The real values – ruby's `wg1.key`/`wg2.key`, the PSKs,
the filled-in configs and the old wg-quick configs (`superseded/`) – live
outside git in `~/projects/homelab-private/wireguard/`.

ruby and jennie each have a clone of the repo at `~/homelab`; deploy steps
run from `~/homelab/wireguard` there. **Never fill a secret into the clone**:
install the template to its destination (`/etc/netplan/`, ...) and fill it
there with `sudo sed -i`, then check `git status` is clean.

For `fill-secrets.py`, copy this directory out of the clone, add the key files from
`homelab-private`, and run `./fill-secrets.py` **there**. It edits files in
place, so it refuses to run inside a git work tree. Never commit a filled file;
public keys are fine, anything else that looks like a WireGuard key is not.
