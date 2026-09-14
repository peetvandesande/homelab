#!/usr/bin/env bash
# Creates the loki container on lenora and installs Loki from apt.grafana.com.
# Idempotent: skips the create if CT 102 exists, skips installs already done.
# Run ON the Proxmox host:  ssh root@192.168.1.21 bash -s < scripts/bootstrap.sh
set -euo pipefail

TEMPLATE="local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
STORAGE="ssdpool"
BRIDGE="vmbr0"
GW="192.168.1.1"
SEARCH="home"
POOL="Infrastructure"          # exact case - "Infrastructure", pct is picky
KEY="/root/.ssh/dns-infra.pub"

VMID=102
HOST=loki
IP=192.168.1.56
CORES=2
MEM=2048
DISK=20                        # chunks + index live on the rootfs; 30d retention

# Same repo Grafana (.54) installs from. Pinned so a rebuild produces the same
# Loki; bump deliberately, together with the config it validates against.
LOKI_VER="3.7.7"

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
    --unprivileged 1 --features nesting=1 \
    --onboot 1 \
    --pool "$POOL" \
    --ssh-public-keys "$KEY" \
    --description "$HOST - Loki log store, see homelab/loki"
fi

pct status "$VMID" | grep -q running || pct start "$VMID"

echo "== waiting for network"
for _ in $(seq 30); do
  ping -c1 -W1 "$IP" >/dev/null 2>&1 && { echo "   $HOST $IP up"; break; }
  sleep 1
done

echo "== installing packages"
pct exec "$VMID" -- bash -euo pipefail -c "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # prometheus-node-exporter: every container exposes :9100, no exceptions.
  apt-get install -y -qq curl ca-certificates gnupg jq prometheus-node-exporter
  systemctl enable --now prometheus-node-exporter

  if [ ! -s /etc/apt/keyrings/grafana.gpg ]; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main' \
      > /etc/apt/sources.list.d/grafana.list
    apt-get update -qq
  fi

  if dpkg -s loki 2>/dev/null | grep -q '^Version: ${LOKI_VER}\$'; then
    echo '   loki ${LOKI_VER} already installed'
  else
    apt-get install -y -qq --allow-downgrades loki=${LOKI_VER}
  fi
  apt-mark hold loki >/dev/null

  # The package creates user loki with primary group nogroup and no loki
  # group at all. Give it one, so the config can be root:loki 0640 without
  # handing it to every nogroup process.
  getent group loki >/dev/null || groupadd --system loki
  usermod -g loki loki
  # Unit runs as loki; the config in this repo puts everything under here.
  install -d -o loki -g loki -m 0750 /var/lib/loki
"

echo "== $HOST ready - now: ca/scripts/enrol.sh $IP $HOST; node-exporter/scripts/deploy.sh $IP; scripts/deploy.sh"
