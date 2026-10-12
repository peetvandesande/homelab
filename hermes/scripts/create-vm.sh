#!/usr/bin/env bash
# Creates the hermes VM on lenora from the Debian 13 cloud image and boots it.
# Idempotent: skips the create if VM 109 exists, but still asserts onboot and
# that it is running.
# Run ON the Proxmox host:  ssh root@192.168.8.21 bash -s < scripts/create-vm.sh
#
# The DHCP reservation for $MAC must exist on the router BEFORE this runs, or
# the first lease comes out of the dynamic pool and cloud-init bakes nothing
# in to fix it.
set -euo pipefail

STORAGE="ssdpool"
BRIDGE="vmbr0"
SEARCH="home"
POOL="Infrastructure"          # exact case
KEY="/root/.ssh/dns-infra.pub"

VMID=109
HOST=hermes
IP=192.168.8.57                # from the reservation, not set here
# Fixed rather than generated, so the router reservation can be made first.
MAC="BC:24:11:1B:5D:14"
CORES=2
MEM=6144                       # mailcow without ClamAV idles around 3G
DISK=40G

IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMG="/var/lib/vz/template/cache/debian-13-genericcloud-amd64.qcow2"

if qm config "$VMID" >/dev/null 2>&1; then
  echo "== $VMID ($HOST) already exists, skipping create"
else
  [[ -s $IMG ]] || { echo "== fetching $IMG_URL"; curl -fsSL -o "$IMG" "$IMG_URL"; }

  echo "== creating $VMID ($HOST)"
  # cloud-init's default user, not root: Debian's cloud.cfg has disable_root,
  # which prefixes root's keys with a "please log in as debian" command.
  # bootstrap.sh moves the key to root and that is the only login thereafter.
  # No --nameserver: DHCP hands out Themis like everywhere else.
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
    --ipconfig0 "ip=dhcp,ip6=auto" \
    --ciuser debian --sshkeys "$KEY" \
    --searchdomain "$SEARCH" \
    --agent enabled=1 \
    --onboot 1 \
    --description "$HOST - mailcow for the Proxmox labs, see homelab/hermes"
  qm disk resize "$VMID" scsi0 "$DISK"
fi

qm config "$VMID" | grep -q '^onboot: 1' || qm set "$VMID" --onboot 1
qm status "$VMID" | grep -q running || qm start "$VMID"

echo "== waiting for $IP"
for _ in $(seq 90); do
  ping -c1 -W1 "$IP" >/dev/null 2>&1 && { echo "   $HOST $IP up"; break; }
  sleep 2
done
ping -c1 -W1 "$IP" >/dev/null 2>&1 \
  || { echo "   $IP not answering - is the reservation for $MAC in place?"; exit 1; }

echo "== $HOST booted - now, from the workstation: hermes/scripts/bootstrap.sh"
