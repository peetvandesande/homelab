#!/usr/bin/env bash
# Proxmox Backup Server's web GUI and API (sally :8007) onto the lab CA.
#
# Rolls back automatically: if the proxy does not come back on the new
# certificate, the one it had before is restored, so sally is never left
# unreachable. Enrol first with ca/scripts/enrol.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.22

require_enrolled "$HOST"

# A mismatched pair would stop the proxy from loading its certificate; refuse
# it here rather than relying on the rollback.
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
  # The original self-signed pair is what a rollback returns to, so a re-run
  # must not replace it with a lab certificate.
  for f in proxy.pem proxy.key; do
    [ -f "/root/$f.bak" ] || cp -p "/etc/proxmox-backup/$f" "/root/$f.bak"
  done
  /etc/homelab-tls/post-renew.d/20-proxmox-backup-proxy
'

ok=0
for _ in $(seq 1 30); do
  if $SSH "root@$HOST" 'curl -sS --max-time 5 --cacert /etc/homelab-tls/root_ca.crt \
       -o /dev/null https://sally.home:8007/ --resolve sally.home:8007:127.0.0.1' 2>/dev/null; then
    ok=1; break
  fi
  sleep 2
done

if [[ $ok -ne 1 ]]; then
  echo "!! the proxy did not come back on the new certificate - rolling back"
  $SSH "root@$HOST" '
    cp -p /root/proxy.pem.bak /etc/proxmox-backup/proxy.pem
    cp -p /root/proxy.key.bak /etc/proxmox-backup/proxy.key
    systemctl restart proxmox-backup-proxy
  '
  echo "   rolled back; sally is on its previous certificate"
  exit 1
fi

echo "   proxy reloaded and serving the lab certificate"
