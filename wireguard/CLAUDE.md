# wireguard

Site-to-site WireGuard between the lab and two OVH servers outside it:
**ruby** (mail, DNS, the road-warrior clients on wg0) and **jennie** (the VPN's
internet exit). The home end is the router's `wgclient1` (wg1, to ruby) and
`wgclient2` (wg3, to jennie) – `router/README.md` covers how the router routes
into them.

Unlike the other top-level directories this is not a container filesystem and
has no `deploy.sh`. It is a hand-run rollout, mid-way through:

- `README.md` – the design and the reference behind every step
- `TASKS.md` – the remaining steps in order, with commands. **Start here.**
  Status was last recorded on 2026-10-16; check the hosts before trusting it.

## Secrets are not in this repo

The repo is public. Every private key and PSK in `ruby/`, `jennie/` and `home/`
is a `<placeholder>`. The real values – ruby's `wg1.key`/`wg2.key`, the PSKs,
the filled-in configs and the old wg-quick configs (`superseded/`) – live
outside git in `~/projects/homelab-private/wireguard/`.

To deploy, copy this directory to ruby as `~/wg`, add the key files from
`homelab-private`, and run `./fill-secrets.py` **there**. It edits files in
place, so it refuses to run inside a git work tree. Never commit a filled file;
public keys are fine, anything else that looks like a WireGuard key is not.
