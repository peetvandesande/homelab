#!/usr/bin/env bash
# First-time setup of the metis VM, from the workstation, after
# scripts/create-vm.sh has booted it on lenora. Moves the SSH key from
# cloud-init's `debian` user to root, installs the NVIDIA driver and Ollama,
# and pulls the models. Idempotent: every step checks before it acts.
#
# The driver is Debian's own nvidia-driver from non-free, a branch that still
# supports Pascal (the P2200 is GP106). It needs one reboot to replace nouveau;
# the script does it and waits.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.58
# Pinned: Ollama upgrades change model formats and GPU support. Bump on
# purpose, then re-run this script.
OLLAMA_VERSION=0.12.0
MODELS="bge-m3 qwen3:4b"

if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
     "root@$HOST" true >/dev/null 2>&1; then
  echo "== moving the key from debian to root"
  $SSH "debian@$HOST" \
    'sudo install -m 0600 -o root -g root ~debian/.ssh/authorized_keys /root/.ssh/authorized_keys'
fi

TZ_NAME=$(readlink /etc/localtime | sed 's|.*zoneinfo/||')
echo "== packages and driver"
$SSH "root@$HOST" "TZ_NAME='$TZ_NAME' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
timedatectl set-timezone "$TZ_NAME"
# non-free for the driver, non-free-firmware for its GSP blobs.
sed -i -E 's/^(Components: .*main)$/\1 contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
grep -q 'non-free ' /etc/apt/sources.list.d/debian.sources
apt-get update -qq
apt-get install -y -qq curl ca-certificates jq qemu-guest-agent prometheus-node-exporter \
  systemd-timesyncd nftables linux-headers-amd64 nvidia-driver firmware-misc-nonfree nvidia-smi
systemctl enable --now qemu-guest-agent nftables >/dev/null
REMOTE

if ! $SSH "root@$HOST" 'nvidia-smi -L' >/dev/null 2>&1; then
  echo "== rebooting to load the nvidia module"
  $SSH "root@$HOST" 'systemctl reboot' || true
  sleep 20
  for _ in $(seq 60); do
    ssh -o BatchMode=yes -o ConnectTimeout=3 "root@$HOST" true 2>/dev/null && break
    sleep 3
  done
fi
$SSH "root@$HOST" 'nvidia-smi -L'

echo "== ollama $OLLAMA_VERSION"
$SSH "root@$HOST" "OLLAMA_VERSION=$OLLAMA_VERSION bash -s" <<'REMOTE'
set -euo pipefail
have=$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [ "$have" != "$OLLAMA_VERSION" ]; then
  curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION="$OLLAMA_VERSION" sh
fi
REMOTE

echo "== config"
push "$HOST" root
$SSH "root@$HOST" 'systemctl daemon-reload && nft -c -f /etc/nftables.conf && systemctl restart nftables ollama'

echo "== models"
for m in $MODELS; do
  $SSH "root@$HOST" "ollama list | grep -q '^${m%%:*}' || ollama pull $m"
done
$SSH "root@$HOST" 'ollama list'
echo "== done - next: ca/scripts/enrol.sh 192.168.8.58 metis, node-exporter, alloy, prometheus, then verify.sh"
