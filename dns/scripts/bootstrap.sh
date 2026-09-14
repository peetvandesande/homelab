#!/usr/bin/env bash
# Creates the three DNS containers on lenora. Idempotent: skips any CT that exists.
# Run ON the Proxmox host.
set -euo pipefail

TEMPLATE="local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
STORAGE="ssdpool"
BRIDGE="vmbr0"
GW="192.168.1.1"
NS="192.168.1.1"
SEARCH="home"
POOL="Infrastructure"
KEY="/root/.ssh/dns-infra.pub"

# vmid hostname ip cores mem disk
CONTAINERS=(
  "105 themis 192.168.1.50 1 512 4"
  "106 delphi 192.168.1.51 2 4096 8"   # RPZ feeds + a 2M-entry record cache
  "107 pythia 192.168.1.52 1 512 4"
)

for entry in "${CONTAINERS[@]}"; do
  read -r vmid host ip cores mem disk <<<"$entry"
  if pct config "$vmid" >/dev/null 2>&1; then
    echo "== $vmid ($host) already exists, skipping create"
  else
    echo "== creating $vmid ($host) $ip"
    pct create "$vmid" "$TEMPLATE" \
      --hostname "$host" \
      --cores "$cores" --memory "$mem" --swap 512 \
      --rootfs "${STORAGE}:${disk}" \
      --net0 "name=eth0,bridge=${BRIDGE},ip=${ip}/24,gw=${GW},ip6=auto,type=veth" \
      --nameserver "$NS" --searchdomain "$SEARCH" \
      --ostype debian --arch amd64 \
      --unprivileged 1 --features nesting=1 \
      --onboot 1 \
      --pool "$POOL" \
      --ssh-public-keys "$KEY" \
      --description "$host - see homelab/dns"
  fi
  pct status "$vmid" | grep -q running || pct start "$vmid"
done

echo "== waiting for network"
for entry in "${CONTAINERS[@]}"; do
  read -r vmid host ip _ <<<"$entry"
  for _ in $(seq 30); do
    ping -c1 -W1 "$ip" >/dev/null 2>&1 && { echo "   $host $ip up"; break; }
    sleep 1
  done
done
pct list
