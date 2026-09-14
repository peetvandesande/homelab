#!/usr/bin/env bash
# Configure esther (ESXi, 192.168.1.20) to log to the lab: trust the CA,
# forward syslog over TLS to the relay on the loki container, and accept the
# SMART puller's SSH key.
#
# Needs SSH enabled on esther (Host > Actions > Services > Enable Secure
# Shell in the Host Client) and a way in: it prompts for root's password
# unless an RSA or ECDSA P-256 workstation key is already installed. ESXi 8
# runs sshd in FIPS mode and refuses ed25519 keys, so the lab's usual
# ~/Documents/sshkey.pub (ed25519) is no use here and is not installed; point
# WSKEY at an ECDSA/RSA key to get a password-free login.
# Run scripts/deploy.sh first - this reads the puller key from the relay.
set -euo pipefail
cd "$(dirname "$0")/.."
ESXI=root@192.168.1.20
RELAY=192.168.1.56
WSKEY="$HOME/Documents/sshkey.pub"
CA_DIR=../ca
E="ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new $ESXI"

[[ -s "$WSKEY" ]] || { echo "no workstation key at $WSKEY"; exit 1; }
keys=("$(cat "$WSKEY")")
if [[ "${keys[0]}" == ssh-ed25519* ]]; then
  echo "note: $WSKEY is ed25519, which esther's FIPS-mode sshd refuses - not installing it; expect a password prompt"
  keys=()
fi
puller=$(ssh -o BatchMode=yes "root@$RELAY" cat /var/lib/esxi-smart/id_ecdsa.pub) \
  || { echo "cannot read the puller key from $RELAY - run scripts/deploy.sh first"; exit 1; }

echo "== esther: version"
$E 'vmware -vl'

echo "== esther: ssh keys (smart puller${keys:+ + workstation})"
# /etc/ssh/keys-root/authorized_keys is in ESXi's persisted set; auto-backup
# writes the state file straight away rather than waiting for the hourly run.
keys+=("$puller")
$E "mkdir -p /etc/ssh/keys-root && touch /etc/ssh/keys-root/authorized_keys
    for k in $(printf "'%s' " "${keys[@]}"); do
      grep -qF \"\$k\" /etc/ssh/keys-root/authorized_keys || echo \"\$k\" >> /etc/ssh/keys-root/authorized_keys
    done
    chmod 0600 /etc/ssh/keys-root/authorized_keys"

echo "== esther: trust the lab CA for syslog"
# Both the root and the G3 intermediate: the relay sends leaf + G3, but a
# complete chain in the store costs nothing and survives a server that does
# not. Idempotent on the root's subject line.
chain=$(cat "$CA_DIR/rootca/certs/root.crt" "$CA_DIR/intermediate/certs/intermediate-g3.crt")
$E "cp -p /etc/vmware/ssl/castore.pem /etc/vmware/ssl/castore.pem.bak 2>/dev/null || true
    if openssl x509 -in /etc/vmware/ssl/castore.pem -noout 2>/dev/null && grep -q 'Peet van de Sande Root' /etc/vmware/ssl/castore.pem; then
      echo '   lab root already in castore.pem'
    else
      printf '%s\n' '$chain' >> /etc/vmware/ssl/castore.pem
      echo '   appended root + G3 intermediate to castore.pem'
    fi"

echo "== esther: syslog -> ssl://$RELAY:1514 (RFC 5424)"
# formatter=RFC_5424: the relay's parser cannot read ESXi's default 3164-with-
# RFC-3339-timestamps output. See relay/etc/alloy/esxi.alloy.
$E "esxcli system syslog config set --loghost='ssl://$RELAY:1514?formatter=RFC_5424' --check-ssl-certs=true
    esxcli system syslog reload
    esxcli network firewall ruleset set --ruleset-id=syslog --enabled=true
    esxcli network firewall refresh
    /sbin/auto-backup.sh >/dev/null
    esxcli system syslog config get | grep -E 'Remote Host|Check SSL'
    esxcli system syslog mark --message='homelab: syslog to loki configured'"

echo "== esther: disks"
$E 'esxcli storage core device list | grep -E "^[^ ]|Model|Is Local|Is USB"'

echo
echo "== esther configured. Now: scripts/verify.sh"
echo "   The Host Client will warn that SSH is enabled; that is deliberate (the SMART"
echo "   pull needs it). Silence the banner with:"
echo "     esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1"
