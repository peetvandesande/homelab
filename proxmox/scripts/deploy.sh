#!/usr/bin/env bash
# Proxmox VE web GUI (lenora, 192.168.1.21:8006) onto the lab CA.
#
# Rolls back automatically. This is the hypervisor's management interface: if
# pveproxy does not come back, the certificate is removed and pveproxy
# restarted on its self-signed one, so the GUI is never left down.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.1.21

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
