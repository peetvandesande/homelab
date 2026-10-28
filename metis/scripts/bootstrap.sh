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
OLLAMA_SHA256=5c6ea489179d534e2f841956fb62af1c97376bde0b759eb109e4911b82c88301
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
apt-get -o DPkg::Lock::Timeout=900 update -qq
apt-get -o DPkg::Lock::Timeout=900 install -y -qq curl ca-certificates jq qemu-guest-agent prometheus-node-exporter \
  systemd-timesyncd nftables linux-image-amd64 linux-headers-amd64 nvidia-driver \
  firmware-misc-nonfree nvidia-smi
# The cloud image boots Debian's trimmed -cloud kernel, but DKMS builds the
# driver for the generic one the headers above belong to. Remove the cloud
# kernel so the generic one is what boots.
if dpkg -l 'linux-image-*cloud*' 2>/dev/null | grep -q '^ii'; then
  apt-get -o DPkg::Lock::Timeout=900 purge -y -qq 'linux-image-*cloud*'
  update-grub
fi
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
# The release tarball, checked against the sha256 below (from the release's
# sha256sum.txt), not upstream's install.sh: nothing from the network is
# executed, and the unit is ours, in root/.
$SSH "root@$HOST" "OLLAMA_VERSION=$OLLAMA_VERSION OLLAMA_SHA256=$OLLAMA_SHA256 bash -s" <<'REMOTE'
set -euo pipefail
have=$(/usr/local/bin/ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || true)
if [ "$have" != "$OLLAMA_VERSION" ]; then
  t=$(mktemp -d)
  curl -fsSL -o "$t/ollama.tgz" \
    "https://github.com/ollama/ollama/releases/download/v$OLLAMA_VERSION/ollama-linux-amd64.tgz"
  echo "$OLLAMA_SHA256  $t/ollama.tgz" | sha256sum -c --quiet
  systemctl stop ollama 2>/dev/null || true
  rm -rf /usr/local/lib/ollama
  tar -C /usr/local -xzf "$t/ollama.tgz"
  rm -rf "$t"
fi
id ollama >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -U -m -d /var/lib/ollama ollama
usermod -aG video,render ollama
REMOTE

echo "== config"
push "$HOST" root
$SSH "root@$HOST" 'systemctl daemon-reload && nft -c -f /etc/nftables.conf && systemctl restart nftables && systemctl enable --now ollama && systemctl restart ollama'

echo "== models"
for m in $MODELS; do
  $SSH "root@$HOST" "ollama list | grep -q '^${m%%:*}' || ollama pull $m"
done
$SSH "root@$HOST" 'ollama list'
echo "== done - next: ca/scripts/enrol.sh 192.168.8.58 metis, node-exporter, alloy, prometheus, then verify.sh"
