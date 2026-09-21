#!/usr/bin/env bash
# Creates the moby container on lenora and installs Docker Engine from
# download.docker.com. Idempotent: skips the create if CT 108 exists, but
# still asserts the settings Docker needs, and skips installs already done.
# Run ON the Proxmox host:  ssh root@192.168.1.21 bash -s < scripts/bootstrap.sh
set -euo pipefail

TEMPLATE="local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
STORAGE="ssdpool"
BRIDGE="vmbr0"
GW="192.168.1.1"
SEARCH="home"
POOL="Infrastructure"          # exact case - "Infrastructure", pct is picky
KEY="/root/.ssh/dns-infra.pub"

VMID=108
HOST=moby
IP=192.168.1.27
CORES=8
MEM=16384
DISK=80                        # images, volumes and build cache all live here

# nesting is the fleet default; keyctl is what Docker adds. Without it the
# kernel keyring calls containerd makes inside an unprivileged container fail,
# and images that touch the keyring (anything using `su`/PAM, for one) break
# in ways that look like permission bugs in the image.
FEATURES="nesting=1,keyctl=1"

if pct config "$VMID" >/dev/null 2>&1; then
  echo "== $VMID ($HOST) already exists, skipping create"
else
  echo "== creating $VMID ($HOST) $IP"
  # No --nameserver: inherit the host resolver, per homelab convention.
  pct create "$VMID" "$TEMPLATE" \
    --hostname "$HOST" \
    --cores "$CORES" --memory "$MEM" --swap 512 \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP}/24,gw=${GW},ip6=auto,type=veth" \
    --searchdomain "$SEARCH" \
    --ostype debian --arch amd64 \
    --unprivileged 1 --features "$FEATURES" \
    --onboot 1 \
    --pool "$POOL" \
    --ssh-public-keys "$KEY" \
    --description "$HOST - Docker container host, see homelab/moby"
fi

# Asserted on every run, not just at create: the container predates this
# script, and a features change only takes effect on a restart.
if [ "$(pct config "$VMID" | sed -n 's/^features: //p')" != "$FEATURES" ]; then
  echo "== setting features=$FEATURES (needs a restart to take effect)"
  pct set "$VMID" --features "$FEATURES"
  pct status "$VMID" | grep -q running && pct reboot "$VMID"
fi
pct config "$VMID" | grep -q '^onboot: 1' || pct set "$VMID" --onboot 1

pct status "$VMID" | grep -q running || pct start "$VMID"

echo "== waiting for network"
for _ in $(seq 30); do
  ping -c1 -W1 "$IP" >/dev/null 2>&1 && { echo "   $HOST $IP up"; break; }
  sleep 1
done

echo "== installing packages"
pct exec "$VMID" -- bash -euo pipefail -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # prometheus-node-exporter: every container exposes :9100, no exceptions.
  # nginx fronts the engine metrics with TLS - see root/etc/nginx.
  apt-get install -y -qq curl ca-certificates gnupg jq nginx prometheus-node-exporter
  systemctl enable --now prometheus-node-exporter

  if [ ! -s /etc/apt/keyrings/docker.gpg ]; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
  fi

  # Upstream Docker, not Debian s docker.io: the compose v2 plugin, buildx and
  # a version anyone migrating a compose file has actually tested against.
  # Unpinned, unlike loki and alloy - the engine s config surface is stable
  # across minors and daemon.json here uses nothing version-specific.
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker

  # Where compose stacks live. One directory per stack, each with its own
  # compose.yaml; named volumes stay under /var/lib/docker.
  install -d -m 0755 /opt/stacks
'

echo "== $HOST ready - now: ca/scripts/enrol.sh $IP $HOST; node-exporter/scripts/deploy.sh $IP; alloy/scripts/deploy.sh $IP; scripts/deploy.sh"
