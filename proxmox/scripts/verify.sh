#!/usr/bin/env bash
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.1.21

echo "== Proxmox web GUI over TLS"
https_ok "pveproxy :8006" "https://$HOST:8006/" 200
chain_ok "lenora:8006" "$HOST:8006"
renewal_ok lenora "$HOST"

echo "== it is our certificate, not Proxmox's self-signed one"
iss=$(echo | openssl s_client -connect "$HOST:8006" 2>/dev/null | openssl x509 -noout -issuer | sed 's/^issuer=//')
if grep -q "Intermediate CA G3" <<<"$iss"; then pass "issued by the G3 intermediate"
else bad "issued by the G3 intermediate" "$iss"; fi

echo "== the cluster's own certificate is untouched"
# pve-ssl.* must stay on Proxmox's internal CA. Replacing it breaks the API,
# and the symptom looks nothing like a TLS problem.
pveiss=$(ssh -o BatchMode=yes root@$HOST 'openssl x509 -in /etc/pve/nodes/$(hostname)/pve-ssl.pem -noout -issuer' 2>/dev/null | sed 's/^issuer=//')
if grep -q "PVE Cluster Manager CA" <<<"$pveiss"; then pass "pve-ssl.pem still issued by the PVE Cluster Manager CA"
else bad "pve-ssl.pem still issued by the PVE Cluster Manager CA" "$pveiss"; fi

echo "== the API still works (proves pve-ssl and pveproxy did not get confused)"
if ssh -o BatchMode=yes root@$HOST 'pvesh get /nodes --output-format json >/dev/null' 2>/dev/null; then
  pass "pvesh get /nodes succeeds"
else bad "pvesh get /nodes succeeds" "the Proxmox API is not answering"; fi

echo "== the renewal hook rebuilds it"
h=$(ssh -o BatchMode=yes root@$HOST 'test -x /etc/homelab-tls/post-renew.d/20-pveproxy && echo yes' 2>/dev/null)
[[ $h == yes ]] && pass "post-renew hook installed and executable" \
  || bad "post-renew hook installed and executable" "missing"

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
