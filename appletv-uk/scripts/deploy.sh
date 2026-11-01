#!/usr/bin/env bash
# Install the Apple TV UK toggle: the script on the router, Home Assistant's
# key and its forced-command authorisation, and the switch in HA.
#
#   scripts/deploy.sh
#
# Idempotent. The key is generated inside HA once and never leaves it; its
# authorized_keys line is replaced by comment, so a rerun after a router
# factory reset puts everything back. The router's DHCP reservation and the
# route_policy.appletv_uk rule are not created here - CLAUDE.md has both.
#
# The first run adds `command_line: !include command_line.yaml` to HA's
# configuration.yaml and restarts core, which a new integration needs. Later
# runs only rewrite command_line.yaml; reload it from Developer tools > YAML >
# Command line entities.
set -euo pipefail

cd "$(dirname "$0")/.."

ROUTER=192.168.8.1
LENORA=192.168.8.21
VMID=302
CONFIG=/mnt/data/supervisor/homeassistant   # /config in the core container
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"
RESTRICT='no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty'

# Run a shell script on the HAOS host, propagating its exit code. Passed as
# base64 so nothing in it needs quoting through ssh and qm.
qexec() {
  local b64
  b64=$(printf '%s' "$1" | base64 | tr -d '\n')
  $SSH "root@$LENORA" "qm guest exec $VMID --timeout 120 -- /bin/sh -c 'echo $b64 | base64 -d | sh'" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.stdout.write(d.get("out-data", "") + d.get("err-data", ""))
sys.exit(int(d.get("exitcode") or 0))
'
}

echo "== router: the toggle"
$SSH "root@$ROUTER" 'uci -q get route_policy.appletv_uk >/dev/null' \
  || { echo "!! route_policy.appletv_uk is missing on the router - see CLAUDE.md" >&2; exit 1; }
# No install(1) on the router's busybox.
$SSH "root@$ROUTER" 'cat > /usr/local/bin/appletv-uk.tmp && chmod 0755 /usr/local/bin/appletv-uk.tmp \
  && mv -f /usr/local/bin/appletv-uk.tmp /usr/local/bin/appletv-uk' \
  < router/usr/local/bin/appletv-uk
echo "   /usr/local/bin/appletv-uk (0755)"

echo "== HA: the key"
# HA's container has ssh but no ssh-keygen; cryptography ships with HA.
PUB=$(qexec "docker exec -i homeassistant python3 - <<'EOF'
import os
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

d, k = '/config/.ssh', '/config/.ssh/appletv_uk'
os.makedirs(d, mode=0o700, exist_ok=True)
os.umask(0o077)
if not os.path.exists(k):
    key = Ed25519PrivateKey.generate()
    open(k, 'wb').write(key.private_bytes(
        s.Encoding.PEM, s.PrivateFormat.OpenSSH, s.NoEncryption()))
    open(k + '.pub', 'wb').write(key.public_key().public_bytes(
        s.Encoding.OpenSSH, s.PublicFormat.OpenSSH) + b' appletv-uk@homeassistant\n')
os.chmod(k, 0o600)
print(' '.join(open(k + '.pub').read().split()[:2]))
EOF")
[[ $PUB == ssh-ed25519\ * ]] || { echo "!! no public key from HA: $PUB" >&2; exit 1; }
echo "   /config/.ssh/appletv_uk"

echo "== router: authorise it"
$SSH "root@$ROUTER" "
  set -e
  f=/etc/dropbear/authorized_keys
  grep -v ' appletv-uk@homeassistant\$' \$f > \$f.tmp || true
  echo 'command=\"/usr/local/bin/appletv-uk\",$RESTRICT $PUB appletv-uk@homeassistant' >> \$f.tmp
  chmod 600 \$f.tmp && mv -f \$f.tmp \$f"
echo "   forced to /usr/local/bin/appletv-uk"

echo "== HA: accept the router's host key"
state=$(qexec "docker exec homeassistant ssh -i /config/.ssh/appletv_uk -o BatchMode=yes \
  -o UserKnownHostsFile=/config/.ssh/known_hosts -o StrictHostKeyChecking=accept-new \
  root@$ROUTER status")
echo "   the toggle answers: $state"

echo "== HA: the switch"
b64=$(base64 < ha/command_line.yaml | tr -d '\n')
qexec "echo $b64 | base64 -d > $CONFIG/command_line.yaml"
echo "   $CONFIG/command_line.yaml"
if qexec "grep -q '^command_line:' $CONFIG/configuration.yaml"; then
  echo "   already included - reload Command line entities in Developer tools > YAML"
else
  qexec "cp $CONFIG/configuration.yaml $CONFIG/configuration.yaml.bak-$(date +%F)-appletv-uk \
    && printf '\ncommand_line: !include command_line.yaml\n' >> $CONFIG/configuration.yaml"
  echo "   included from configuration.yaml - checking and restarting core"
  qexec "ha core check" >/dev/null
  qexec "ha core restart" >/dev/null
fi

echo
echo "== deployed - now run scripts/verify.sh"
