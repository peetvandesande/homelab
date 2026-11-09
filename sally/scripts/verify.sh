#!/usr/bin/env bash
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.8.22

echo "== Proxmox Backup Server over TLS"
https_ok "proxy by name" "https://sally.home:8007/" 200
https_ok "proxy by address" "https://$HOST:8007/" 200
chain_ok "sally:8007" "$HOST:8007"
renewal_ok sally "$HOST"

echo "== it is our certificate, not the self-signed one"
iss=$(echo | openssl s_client -connect "$HOST:8007" 2>/dev/null | openssl x509 -noout -issuer | sed 's/^issuer=//')
if grep -q "Intermediate CA G3" <<<"$iss"; then pass "issued by the G3 intermediate"
else bad "issued by the G3 intermediate" "$iss"; fi

echo "== the renewal hook rebuilds it"
h=$(ssh -o BatchMode=yes root@$HOST 'test -x /etc/homelab-tls/post-renew.d/20-proxmox-backup-proxy && echo yes' 2>/dev/null)
[[ $h == yes ]] && pass "post-renew hook installed and executable" \
  || bad "post-renew hook installed and executable" "missing"

echo "== the proxy can read what it serves"
perms=$(ssh -o BatchMode=yes root@$HOST 'stat -c "%U:%G %a" /etc/proxmox-backup/proxy.key /etc/proxmox-backup/proxy.pem | sort -u' 2>/dev/null)
[[ $perms == "root:backup 640" ]] && pass "proxy.key and proxy.pem are root:backup 0640" \
  || bad "proxy.key and proxy.pem are root:backup 0640" "$perms"

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
