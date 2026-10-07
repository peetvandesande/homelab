#!/usr/bin/env bash
# Issue Home Assistant a fresh certificate from the lab CA.
#
#   scripts/issue.sh [extra-san ...]
#
# Use this for the first issue, and again if the certificate ever lapses -
# step-ca has allowRenewalAfterExpiry false, so an expired certificate cannot
# renew itself and has to be reissued. Day to day, renewal is the timer this
# directory installs on lenora, not this script.
#
# The key is generated inside HAOS and only a CSR comes out, the same rule
# ca/scripts/enrol.sh follows for every other host. HAOS cannot run step-cli,
# so the signing happens on pistis against the CSR rather than on the target.
set -euo pipefail

cd "$(dirname "$0")/.."

LENORA=192.168.8.21
PISTIS=192.168.8.55
VMID=302
CA_URL="https://$PISTIS:8443"
CONFIG=/mnt/data/supervisor/homeassistant   # /config in the core container
SSLDIR=/mnt/data/supervisor/ssl             # /ssl    in the core container
SUBJECT=homeassistant.home
# Home Assistant is on the LAN only. .local is the mDNS name the companion
# apps and AirPlay-ish clients use; it resolves nowhere in our DNS but clients
# do ask for it, so it has to be in the certificate.
SANS=(homeassistant.home homeassistant.local 192.168.8.90 "$@")

ROOT=../ca/rootca/certs/root.crt
[[ -f $ROOT ]] || { echo "missing $ROOT - run this from a checkout with ca/ present"; exit 1; }

SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

# Run a command in the guest, propagating the guest's own exit code.
qexec() {
  $SSH "root@$LENORA" "qm guest exec $VMID --timeout 120 -- /bin/sh -c $(printf '%q' "$1")" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.stdout.write(d.get("out-data", "") + d.get("err-data", ""))
sys.exit(int(d.get("exitcode") or 0))
'
}

echo "== generating key and CSR inside HAOS"
b64=$(base64 < haos/ha-tls.py | tr -d '\n')
qexec "echo $b64 | base64 -d > $CONFIG/ha-tls.py" >/dev/null
sanargs=""
for s in "${SANS[@]}"; do sanargs="$sanargs --san $s"; done
qexec "docker exec homeassistant python3 /config/ha-tls.py csr --subject $SUBJECT$sanargs"

echo "== moving the key into /ssl (host side - /ssl is read-only to the container)"
qexec "set -e
  cp $CONFIG/ha-tls.key.new $SSLDIR/homeassistant.key
  chmod 600 $SSLDIR/homeassistant.key
  rm -f $CONFIG/ha-tls.key.new"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
qexec "cat $CONFIG/ha-tls.csr" > "$tmp/ha.csr"
qexec "rm -f $CONFIG/ha-tls.csr $CONFIG/ha-tls.py" >/dev/null
grep -q "BEGIN CERTIFICATE REQUEST" "$tmp/ha.csr" || { echo "no CSR came back"; exit 1; }

echo "== signing on pistis"
scp -q "$tmp/ha.csr" "root@$PISTIS:/tmp/ha-issue.csr"
tokensans=""
for s in "${SANS[@]}"; do tokensans="$tokensans --san $s"; done
# shellcheck disable=SC2029  # the SAN list is meant to expand locally
$SSH "root@$PISTIS" "set -e
  TOKEN=\$(step ca token $SUBJECT$tokensans \
    --provisioner admin --provisioner-password-file /etc/step-ca/secrets/jwk-password \
    --ca-url '$CA_URL' --root /etc/step-ca/certs/root_ca.crt 2>/dev/null)
  [ -n \"\$TOKEN\" ] || { echo 'token mint failed' >&2; exit 1; }
  # step ca sign already emits leaf+intermediate, which is the bundle Home
  # Assistant wants - do not append the intermediate again.
  step ca sign /tmp/ha-issue.csr /tmp/ha-issue.crt --token \"\$TOKEN\" \
    --ca-url '$CA_URL' --root /etc/step-ca/certs/root_ca.crt -f >/dev/null
  rm -f /tmp/ha-issue.csr"
$SSH "root@$PISTIS" "cat /tmp/ha-issue.crt" > "$tmp/ha.crt"
$SSH "root@$PISTIS" "rm -f /tmp/ha-issue.crt"
[[ $(grep -c "BEGIN CERTIFICATE" "$tmp/ha.crt") -ge 2 ]] || { echo "signed bundle is not leaf+intermediate"; exit 1; }

echo "== installing the certificate and the lab root into /ssl"
b64=$(base64 < "$tmp/ha.crt" | tr -d '\n')
qexec "echo $b64 | base64 -d > $SSLDIR/homeassistant.crt && chmod 644 $SSLDIR/homeassistant.crt" >/dev/null
# The root goes in so renewal can verify the CA instead of trusting blindly.
b64=$(base64 < "$ROOT" | tr -d '\n')
qexec "echo $b64 | base64 -d > $SSLDIR/root_ca.crt && chmod 644 $SSLDIR/root_ca.crt" >/dev/null

echo "== installed:"
b64=$(base64 < haos/ha-tls.py | tr -d '\n')
qexec "echo $b64 | base64 -d > $CONFIG/ha-tls.py" >/dev/null
qexec "docker exec homeassistant python3 /config/ha-tls.py info"
qexec "rm -f $CONFIG/ha-tls.py" >/dev/null

cat <<'EOF'

Not done here, on purpose:
  * configuration.yaml is yours. Home Assistant needs
      http:
        ssl_certificate: /ssl/homeassistant.crt
        ssl_key: /ssl/homeassistant.key
    and the supervisor needs to agree - `ha core options --ssl=true --port 443`
    (or whatever server_port you set). A mismatch between the two is what makes
    HA look broken.
  * Home Assistant was not restarted. It reads the certificate at startup.
EOF
