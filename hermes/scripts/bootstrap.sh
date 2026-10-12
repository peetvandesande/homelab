#!/usr/bin/env bash
# First-time setup of the hermes VM, from the workstation, after
# scripts/create-vm.sh has booted it on lenora. Moves the SSH key from
# cloud-init's `debian` user to root, installs Docker Engine and node-exporter,
# clones mailcow and generates its config. Idempotent: every step checks
# before it acts, and mailcow.conf is generated only once - it holds the
# passwords, so a second generate would orphan the database.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.57
FQDN=hermes.home
MC=/opt/mailcow-dockerized
# The workstation's zone, so mail timestamps read the same as everything else.
TZ_NAME=$(readlink /etc/localtime | sed 's|.*zoneinfo/||')

# Plain ssh for the probe, not $SSH: a multiplexed master opened here would
# keep the forced command below for every later session over it.
if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
     "root@$HOST" true >/dev/null 2>&1; then
  echo "== moving the key from debian to root"
  # Overwrite rather than append: cloud-init already put the same key in root's
  # file behind a "please log in as debian" command, and sshd takes the first
  # matching line.
  $SSH "debian@$HOST" \
    'sudo install -m 0600 -o root -g root ~debian/.ssh/authorized_keys /root/.ssh/authorized_keys'
fi

echo "== packages"
$SSH "root@$HOST" "TZ_NAME='$TZ_NAME' bash -s" <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
timedatectl set-timezone "$TZ_NAME"
apt-get update -qq
# git: mailcow installs and updates from its repository.
# qemu-guest-agent: so lenora can reach the VM with the network down.
# prometheus-node-exporter: every host exposes :9100, no exceptions.
apt-get install -y -qq curl ca-certificates gnupg jq git qemu-guest-agent \
  prometheus-node-exporter systemd-timesyncd
systemctl enable --now qemu-guest-agent prometheus-node-exporter

# The router is the LAN's NTP server; by IP, so time does not wait on DNS.
install -d /etc/systemd/timesyncd.conf.d
printf '[Time]\nNTP=192.168.8.1\n' > /etc/systemd/timesyncd.conf.d/router.conf
systemctl restart systemd-timesyncd

if [ ! -s /etc/apt/keyrings/docker.gpg ]; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
fi
# Upstream Docker, not Debian's: mailcow wants compose v2 and Docker >= 24.
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
EOF

echo "== mailcow"
$SSH "root@$HOST" "[ -d $MC/.git ] || git clone -q https://github.com/mailcow/mailcow-dockerized $MC"
# Before generate_config.sh: it refuses to continue without ipv6 in daemon.json,
# and the overrides and postfix/rspamd files belong in the clone from the start.
push "$HOST" root
$SSH "root@$HOST" "
  set -e
  dockerd --validate --config-file /etc/docker/daemon.json
  systemctl restart docker
  cd $MC
  if [ -f mailcow.conf ]; then
    echo '   mailcow.conf exists, not regenerating'
  else
    ln -sf mailcow.conf .env
    MAILCOW_HOSTNAME=$FQDN MAILCOW_TZ='$TZ_NAME' MAILCOW_BRANCH=master SKIP_CLAMD=y \
      ./generate_config.sh </dev/null
  fi
"

echo "== $FQDN ready - now: ca/scripts/enrol.sh $HOST hermes; node-exporter/scripts/deploy.sh $HOST; alloy/scripts/deploy.sh $HOST; hermes/scripts/deploy.sh"
