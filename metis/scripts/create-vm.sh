#!/usr/bin/env bash
# Creates the metis VM on lenora from the Debian 13 cloud image, with the
# Quadro P2200 passed through, and boots it. Idempotent: skips the create if
# VM 110 exists, but still asserts the GPU, onboot and that it is running.
# Run ON the Proxmox host:  ssh root@192.168.8.21 bash -s < scripts/create-vm.sh
#
# Two things must be true first:
# - the DHCP reservation for $MAC is on the router, or the first lease comes
#   out of the dynamic pool and cloud-init bakes nothing in to fix it;
# - uc1-worker-1 has let go of the GPU (gpu_worker = false in
#   uc1-lab/terraform.tfvars, then tofu apply). A PCI device can be attached
#   to one running VM only; qm start fails here if the worker still has it.
set -euo pipefail

STORAGE="ssdpool"
BRIDGE="vmbr0"
SEARCH="home"
POOL="Infrastructure"          # exact case
KEY="/root/.ssh/dns-infra.pub"

VMID=110
HOST=metis
IP=192.168.8.58                # from the reservation, not set here
# Fixed rather than generated, so the router reservation can be made first.
MAC="BC:24:11:6E:7A:19"
CORES=8
MEM=16384                      # models live in VRAM; RAM is for the CPU fallback
DISK=80G                       # model store
# The cluster resource mapping uc1-lab created for the card. The name is
# historical; it is just the P2200 (GPU + audio function).
GPU_MAPPING=uc1-gpu

IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMG="/var/lib/vz/template/cache/debian-13-genericcloud-amd64.qcow2"

if qm config "$VMID" >/dev/null 2>&1; then
  echo "== $VMID ($HOST) already exists, skipping create"
else
  [[ -s $IMG ]] || { echo "== fetching $IMG_URL"; curl -fsSL -o "$IMG" "$IMG_URL"; }

  echo "== creating $VMID ($HOST)"
  # Same shape as hermes. q35 for PCIe passthrough; SeaBIOS, so Secure Boot
  # never gets in the way of the unsigned nvidia module; no balloon, because
  # a passed-through device pins all guest memory anyway.
  qm create "$VMID" \
    --name "$HOST" \
    --pool "$POOL" \
    --ostype l26 --machine q35 --cpu host \
    --cores "$CORES" --memory "$MEM" --balloon 0 \
    --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}:0,import-from=${IMG},discard=on,iothread=1,ssd=1" \
    --ide2 "${STORAGE}:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket --vga serial0 \
    --net0 "virtio=${MAC},bridge=${BRIDGE}" \
    --ipconfig0 "ip=dhcp" \
    --ciuser debian --sshkeys "$KEY" \
    --searchdomain "$SEARCH" \
    --agent enabled=1 \
    --onboot 1 \
    --description "$HOST - Ollama on the Quadro P2200 for the job search pipelines, see homelab/metis"
  qm disk resize "$VMID" scsi0 "$DISK"
fi

# rombar=0: with no emulated VGA (vga: serial0), SeaBIOS hangs running the
# card's option ROM and the guest never boots - no DHCP request, no console.
# The Linux driver does not need the ROM. uc1-worker-1 got away with rombar=1
# because it kept the default emulated VGA.
qm config "$VMID" | grep -q "^hostpci0: mapping=$GPU_MAPPING,pcie=1,rombar=0" \
  || qm set "$VMID" --hostpci0 "mapping=$GPU_MAPPING,pcie=1,rombar=0,x-vga=0"
qm config "$VMID" | grep -q '^onboot: 1' || qm set "$VMID" --onboot 1
qm status "$VMID" | grep -q running || qm start "$VMID"

echo "== waiting for $IP"
for _ in $(seq 90); do
  ping -c1 -W1 "$IP" >/dev/null 2>&1 && { echo "   $HOST $IP up"; break; }
  sleep 2
done
ping -c1 -W1 "$IP" >/dev/null 2>&1 \
  || { echo "   $IP not answering - is the reservation for $MAC in place?"; exit 1; }

echo "== $HOST booted - now, from the workstation: metis/scripts/bootstrap.sh"
