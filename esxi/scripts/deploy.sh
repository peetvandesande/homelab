#!/usr/bin/env bash
# The lab side of ESXi logging, on the loki container (192.168.1.56):
#   - esxi.alloy: a TLS syslog listener on :1514 beside the fleet Alloy file
#   - esxi-smart: hourly SMART pull over SSH, pushed to Loki
#
# Idempotent. Run alloy/scripts/deploy.sh first at least once - this relies
# on /etc/default/alloy pointing at the directory. The ESXi host itself is
# configured by scripts/configure-host.sh, which needs SSH enabled on esther.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.1.56
CA_ROOT=../ca/rootca/certs/root.crt

require_enrolled "$HOST"
push "$HOST" relay
$SSH "root@$HOST" '
  set -e
  grep -q "^CONFIG_FILE=\"/etc/alloy\"$" /etc/default/alloy \
    || { echo "alloy is not in directory mode - run alloy/scripts/deploy.sh first"; exit 1; }
  chown root:alloy /etc/alloy/*.alloy && chmod 0640 /etc/alloy/*.alloy
  alloy validate /etc/alloy >/dev/null
  chmod +x /usr/local/bin/esxi-smart
  # A dedicated key for the puller, generated here so it never leaves the
  # container. configure-host.sh reads the public half to install on esther.
  # ECDSA P-256, not ed25519: ESXi 8 runs sshd in FIPS mode and only accepts
  # rsa-sha2-* and ecdsa-sha2-nistp256 - an ed25519 key is refused outright.
  install -d -m 0700 /var/lib/esxi-smart
  [ -s /var/lib/esxi-smart/id_ecdsa ] \
    || ssh-keygen -q -t ecdsa -b 256 -N "" -C "esxi-smart@loki" -f /var/lib/esxi-smart/id_ecdsa
  systemctl daemon-reload
  systemctl enable --now esxi-smart.timer >/dev/null
'
restart_assert "$HOST" alloy

# The listener must be up and speaking TLS off our root before esther is
# pointed at it. A handshake is enough here; end-to-end is verify.sh.
ok=0
for _ in $(seq 1 10); do
  # </dev/null, not echo |: a stray newline into the listener logs a framing
  # warning in Alloy's journal on every deploy.
  openssl s_client -connect "$HOST:1514" -CAfile "$CA_ROOT" </dev/null 2>/dev/null \
    | grep -q "Verify return code: 0 (ok)" && { ok=1; break; }
  sleep 3
done
if [[ $ok -eq 1 ]]; then
  echo "   $HOST:1514 syslog listener up, verifies against the G2 root"
else
  echo "   $HOST:1514 FAILED TLS handshake"; $SSH "root@$HOST" 'journalctl -u alloy --no-pager -n 20'; exit 1
fi

echo
echo "== relay ready. Puller public key (configure-host.sh installs it on esther):"
$SSH "root@$HOST" 'cat /var/lib/esxi-smart/id_ecdsa.pub'
