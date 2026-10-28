#!/usr/bin/env bash
# Creates the forgejo container on lenora and installs Forgejo, PostgreSQL and
# the fleet's node-exporter. Idempotent: skips the create if CT 303 exists and
# skips installs already done. Run ON the Proxmox host, from the workstation:
#
#   ssh root@lenora.home "KEY='$(cat ~/Documents/sshkey.pub)' bash -s" < scripts/bootstrap.sh
#
# The router reservation must exist first (../CLAUDE.md, "Container
# defaults"): 192.168.8.62 is keyed to the MAC below, and a container started
# without it lands in the dynamic pool.
set -euo pipefail

TEMPLATE="local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
STORAGE="ssdpool"
POOL="Production"              # exact case - pct is picky

VMID=303
HOST=forgejo
IP=192.168.8.62
# The router's reservation and the SLAAC ULA in DNS and the certificate all
# key off this. Rebuild with the same MAC or change all three.
HWADDR=BC:24:11:14:EC:A4
CORES=4
MEM=4096
DISK=32

# Forgejo's release, from Codeberg. v15 is the LTS line. The binary is
# installed versioned and symlinked, so an upgrade is a new VERSION here and a
# re-run, and a rollback is the old symlink.
VERSION=15.0.11

[[ -n "${KEY:-}" ]] || { echo "KEY is empty - pass the workstation's ~/Documents/sshkey.pub"; exit 1; }
keyfile=$(mktemp); trap 'rm -f "$keyfile"' EXIT
printf '%s\n' "$KEY" > "$keyfile"

if pct config "$VMID" >/dev/null 2>&1; then
  echo "== $VMID ($HOST) already exists, skipping create"
else
  echo "== creating $VMID ($HOST)"
  # ip=dhcp with no gw= and no ip6= at all: the address comes from the
  # reservation, IPv6 from SLAAC. ip6=auto would wedge networking.service on
  # dhclient -6 (../CLAUDE.md). No --nameserver: inherit the host resolver.
  pct create "$VMID" "$TEMPLATE" \
    --hostname "$HOST" \
    --cores "$CORES" --memory "$MEM" --swap 512 \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=vmbr0,firewall=1,hwaddr=${HWADDR},ip=dhcp,type=veth" \
    --searchdomain home \
    --ostype debian --arch amd64 \
    --unprivileged 1 --features nesting=1 \
    --onboot 1 \
    --pool "$POOL" \
    --ssh-public-keys "$keyfile" \
    --description "$HOST - Forgejo, see homelab/forgejo"
fi

pct status "$VMID" | grep -q running || pct start "$VMID"

echo "== waiting for network"
for _ in $(seq 60); do
  ping -c1 -W1 "$IP" >/dev/null 2>&1 && { echo "   $HOST $IP up"; break; }
  sleep 1
done
ping -c1 -W1 "$IP" >/dev/null 2>&1 || { echo "!! $IP never answered - is the reservation on the router?"; exit 1; }

echo "== installing packages"
pct exec "$VMID" -- env VERSION="$VERSION" bash -euo pipefail -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # prometheus-node-exporter: every container exposes :9100, no exceptions.
  apt-get install -y -qq curl ca-certificates git git-lfs openssh-server \
    postgresql prometheus-node-exporter
  systemctl enable --now prometheus-node-exporter postgresql

  # The service account. Its shell must be a real one: OpenSSH runs the
  # forced command through it for every git push and pull.
  getent passwd git >/dev/null || \
    adduser --system --group --shell /bin/bash --home /var/lib/forgejo \
      --gecos "Forgejo" git
  passwd -l git >/dev/null
  install -d -o git -g git -m 0750 /var/lib/forgejo /var/lib/forgejo/custom
  install -d -o root -g git -m 0750 /etc/forgejo

  # The database role is named after the OS user, so Forgejo connects over
  # the Unix socket with peer authentication and there is no password at all.
  runuser -u postgres -- psql -tA -c "\\du git" | grep -q "^git" \
    || runuser -u postgres -- createuser git
  runuser -u postgres -- psql -tA -l | grep -q "^forgejo|" \
    || runuser -u postgres -- createdb -O git -E UTF8 -T template0 forgejo

  bin=/usr/local/bin/forgejo-$VERSION
  if [ ! -x "$bin" ]; then
    base=https://codeberg.org/forgejo/forgejo/releases/download/v$VERSION
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/forgejo-$VERSION-linux-amd64" "$base/forgejo-$VERSION-linux-amd64"
    curl -fsSL -o "$tmp/forgejo-$VERSION-linux-amd64.sha256" "$base/forgejo-$VERSION-linux-amd64.sha256"
    (cd "$tmp" && sha256sum -c "forgejo-$VERSION-linux-amd64.sha256")
    install -m 0755 "$tmp/forgejo-$VERSION-linux-amd64" "$bin"
    rm -rf "$tmp"
  fi
  ln -sfn "$bin" /usr/local/bin/forgejo
  /usr/local/bin/forgejo --version
'

echo "== $HOST ready - now: ca/scripts/enrol.sh $IP $HOST git.peetvandesande.com; node-exporter, alloy, apt, fleet; scripts/deploy.sh"
