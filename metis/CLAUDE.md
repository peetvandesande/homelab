# metis

VM 110, **192.168.8.58**, `Infrastructure` pool, `ollama.home` as a CNAME.
**Ollama on the Quadro P2200** for the job search pipelines: `bge-m3`
embeddings for both n8n stacks on moby, plus `qwen3:4b` as an optional local
scorer. Built 28 October 2026.

```
scripts/create-vm.sh   on lenora: create VM 110 from the Debian 13 cloud image, GPU attached
scripts/bootstrap.sh   from the workstation: driver, Ollama (pinned), push root/, pull models
scripts/verify.sh      GPU, Ollama, the embed path from n8n, exposure, monitoring
```

From scratch: router reservation for `BC:24:11:6E:7A:19` → `gpu_worker = false`
in `uc1-lab/terraform.tfvars` and `tofu apply` → `create-vm.sh` →
`bootstrap.sh` → `dns/ansible` zones → `ca/scripts/enrol.sh 192.168.8.58 metis`
→ `node-exporter/scripts/deploy.sh 192.168.8.58` →
`alloy/scripts/deploy.sh 192.168.8.58` → `prometheus/scripts/deploy.sh` →
`verify.sh`.

## Why a VM

The card is bound to `vfio-pci` on lenora and `nvidia` is blacklisted there
(`proxmox/CLAUDE.md`, "The GPU is not the host's"), so an LXC could only have
it by giving the host the driver back. Passthrough to a VM keeps lenora as it
is and makes the card a unit you can hand to one guest or another.

## Invariants

1. **The card goes to one running VM at a time.** It used to be uc1-worker-1's;
   it is now metis's, through the same `uc1-gpu` resource mapping. Giving it
   back means stopping metis first, and the pipelines lose embeddings until
   it returns (W2 fails and retries next day; nothing is lost).
2. **The driver is Debian's `nvidia-driver`**, a branch that still supports
   Pascal. NVIDIA's own 595+ branches dropped it (`uc1-lab/network.conf`), so
   never install the driver from NVIDIA's repository here.
3. **Ollama has no authentication.** It listens on every address and
   `/etc/nftables.d/ollama.nft` admits only moby (both n8n stacks egress as
   moby) and loopback. Plain HTTP on the LAN, by choice: n8n would otherwise
   need the lab root in its trust store.
4. **Ollama is pinned** (`OLLAMA_VERSION` and its `OLLAMA_SHA256` in
   `bootstrap.sh`), installed from the release tarball with our own unit in
   `root/` – never upstream's `install.sh` piped into a shell. An upgrade can
   change GPU support; bump both on purpose and re-run `bootstrap.sh` and
   `verify.sh`.
5. **`rombar=0` on the passthrough.** metis has no emulated VGA
   (`vga: serial0`), and with the card's option ROM exposed SeaBIOS hangs
   before the guest boots – no console, no DHCP request, nothing in any log.
   uc1-worker-1 got away with `rombar=1` only because it kept a VGA.
6. **The generic kernel, not the cloud one.** Debian's cloud image boots the
   trimmed `-cloud` kernel; DKMS builds nvidia for `linux-headers-amd64`, the
   generic one. `bootstrap.sh` installs the generic kernel and purges the cloud
   kernel. If `nvidia-smi` cannot reach the driver after an upgrade, check
   `uname -r` first.
7. **bge-m3 vectors are 1024-dim** and stored in each pipeline's pgvector
   column of that size. Changing the embedding model means re-embedding every
   job and the profile, not just pulling a new model.
