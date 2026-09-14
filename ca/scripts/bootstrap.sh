#!/usr/bin/env bash
# Creates the pistis container on lenora and installs smallstep.
# Idempotent: skips the create if CT 101 exists, skips installs already done.
# Run ON the Proxmox host.
set -euo pipefail

TEMPLATE="local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
STORAGE="ssdpool"
BRIDGE="vmbr0"
GW="192.168.1.1"
SEARCH="home"
POOL="Infrastructure"          # exact case - "Infrastructure", pct is picky
KEY="/root/.ssh/dns-infra.pub"

VMID=101
HOST=pistis
IP=192.168.1.55
CORES=2
MEM=1024
DISK=8

# smallstep is not in Debian. Pinned rather than "latest" so a rebuild six
# months from now produces the same CA - and so an upstream release cannot
# change the signing behaviour of a running CA behind your back.
# Note the "-1": the .deb assets carry a Debian revision that the git tag does
# not, and both the filename and dpkg's recorded Version include it.
STEP_CA_VER="0.30.2-1"
STEP_CLI_VER="0.30.6-1"

if pct config "$VMID" >/dev/null 2>&1; then
  echo "== $VMID ($HOST) already exists, skipping create"
else
  echo "== creating $VMID ($HOST) $IP"
  # No --nameserver: inherit the host resolver, per homelab convention. Pistis
  # is not part of the DNS stack, so it has no reason to pin one.
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
    --description "$HOST - smallstep CA, see homelab/ca"
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
  apt-get install -y -qq curl ca-certificates nginx jq prometheus-node-exporter
  systemctl enable --now prometheus-node-exporter

  arch=amd64
  for pkg in step-ca:${STEP_CA_VER}:certificates step-cli:${STEP_CLI_VER}:cli; do
    name=\${pkg%%:*}; rest=\${pkg#*:}; ver=\${rest%%:*}; repo=\${rest#*:}
    if dpkg -s \"\$name\" 2>/dev/null | grep -q \"^Version: \$ver\"; then
      echo \"   \$name \$ver already installed\"
      continue
    fi
    echo \"   installing \$name \$ver\"
    curl -fsSL -o /tmp/\$name.deb \
      \"https://github.com/smallstep/\$repo/releases/download/v\${ver%-*}/\${name}_\${ver}_\${arch}.deb\"
    dpkg -i /tmp/\$name.deb
    rm -f /tmp/\$name.deb
  done

  # step-ca runs as its own unprivileged user; the intermediate key is readable
  # by nobody else.
  id -u step >/dev/null 2>&1 || useradd --system --home /var/lib/step-ca --shell /usr/sbin/nologin step
  install -d -o step -g step -m 0700 /var/lib/step-ca /etc/step-ca/secrets
  install -d -o step -g step -m 0755 /etc/step-ca /etc/step-ca/config /etc/step-ca/certs
  install -d -o root -g root -m 0755 /var/www /var/www/g3
"

echo "== $HOST ready - now run scripts/make-intermediate.sh, then scripts/deploy.sh"
