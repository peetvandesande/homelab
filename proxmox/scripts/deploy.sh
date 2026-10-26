#!/usr/bin/env bash
# Proxmox VE web GUI (lenora, 192.168.8.21:8006) onto the lab CA.
#
# Rolls back automatically. This is the hypervisor's management interface: if
# pveproxy does not come back, the certificate is removed and pveproxy
# restarted on its self-signed one, so the GUI is never left down.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.21

require_enrolled "$HOST"

# Refuse to install a mismatched pair. pveproxy would fail to start, and the
# rollback below would fire - better not to restart it at all.
$SSH "root@$HOST" '
  set -e
  c=$(openssl x509 -in /etc/homelab-tls/host.crt -noout -pubkey | openssl sha256)
  k=$(openssl pkey -in /etc/homelab-tls/host.key -pubout | openssl sha256)
  [ "$c" = "$k" ] || { echo "certificate and key do not match"; exit 1; }
'
echo "   certificate and key match"

push "$HOST" root

# ----------------------------------------------------------------- IPv6 -----
# root/etc/network/interfaces.d/ipv6-ula is pushed with everything else, and
# the stanza applies itself on the next boot. Apply it now with `ip` rather
# than `ifup`: bringing an interface up or down on the Proxmox host is how you
# lose every container's networking and your own session with it, and this
# change only ever ADDS an address and an off-link route. Both commands are
# idempotent, so a re-run is a no-op.
echo "== IPv6 ULA on vmbr0"
$SSH "root@$HOST" '
  set -e
  ip -6 addr replace fd33:5692:1834:1000::21/64 dev vmbr0
  ip -6 route replace fd33:5692:1834::/48 via fd33:5692:1834:1000::1 dev vmbr0
'
$SSH "root@$HOST" "ip -6 addr show dev vmbr0 | grep -q 'fd33:5692:1834:1000::21/64'" \
  && echo "   fd33:5692:1834:1000::21 is up" \
  || { echo "!! the ULA is not on vmbr0"; exit 1; }

# ------------------------------------------------------------------ NFS -----
# /etc/exports is pushed with everything else under root/; reapply it. Only
# `exportfs -ra` is needed - the export set is re-read, nfs-server is not
# restarted and existing mounts are not disturbed.
$SSH "root@$HOST" '
  set -e
  exportfs -ra
  exportfs -v | grep -q "^/hddpool/media" || { echo "/hddpool/media is not exported"; exit 1; }
'
echo "   NFS exports reapplied"

# ------------------------------------------------------------------ NTP -----
# chrony.conf is pushed with root/; a restart is needed to drop the old sources.
$SSH "root@$HOST" '
  set -e
  systemctl restart chrony
  for _ in $(seq 1 15); do
    chronyc -n sources | grep -q "^\^\* 192\.168\.8\.1 " && exit 0
    sleep 2
  done
  echo "chrony is not synced to the router"; chronyc -n sources; exit 1
'
echo "   chrony synced to the router"

# ------------------------------------------------------------------ GPU -----
# The Quadro P2200 is bound to vfio-pci for uc1-lab (modprobe.d/uc1-vfio.conf)
# and nvidia is blacklisted, so the host can never initialise it. The two units
# the driver package ships fail on every boot and fired systemd-unit-failed.
# Lenora-only, so this is not in fleet/masked-units. reset-failed follows the
# mask for the same reason as there: masking does not clear a failed state.
echo "== host NVIDIA units"
$SSH "root@$HOST" '
  set -e
  systemctl mask nvidia-devnodes.service nvidia-persistenced.service
  systemctl reset-failed nvidia-devnodes.service nvidia-persistenced.service
'
echo "   nvidia-devnodes and nvidia-persistenced masked"

$SSH "root@$HOST" '
  set -e
  node=$(hostname)
  chmod +x /etc/homelab-tls/post-renew.d/20-pveproxy
  # Keep whatever was there, so rollback is a move rather than a guess.
  for f in pveproxy-ssl.pem pveproxy-ssl.key; do
    [ -f "/etc/pve/nodes/$node/$f" ] && cp "/etc/pve/nodes/$node/$f" "/root/$f.bak" || true
  done
  /etc/homelab-tls/post-renew.d/20-pveproxy
'

# Assert the GUI actually came back, on our certificate.
ok=0
for _ in $(seq 1 30); do
  if $SSH "root@$HOST" 'curl -sS --max-time 5 --cacert /etc/homelab-tls/root_ca.crt \
       -o /dev/null https://lenora.home:8006/ --resolve lenora.home:8006:127.0.0.1' 2>/dev/null; then
    ok=1; break
  fi
  sleep 2
done

if [[ $ok -ne 1 ]]; then
  echo "!! pveproxy did not come back on the new certificate - rolling back"
  $SSH "root@$HOST" '
    node=$(hostname)
    rm -f "/etc/pve/nodes/$node/pveproxy-ssl.pem" "/etc/pve/nodes/$node/pveproxy-ssl.key"
    for f in pveproxy-ssl.pem pveproxy-ssl.key; do
      [ -f "/root/$f.bak" ] && cp "/root/$f.bak" "/etc/pve/nodes/$node/$f" || true
    done
    systemctl restart pveproxy
  '
  echo "   rolled back; the GUI is back on its previous certificate"
  exit 1
fi

echo "   pveproxy restarted and serving the lab certificate"
