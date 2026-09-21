#!/usr/bin/env bash
# Enrol a host with the CA: install the root as a trust anchor, issue it a
# certificate, and set up unattended renewal.
#
#   scripts/enrol.sh <ip> <shortname> [extra-san ...]
#   scripts/enrol.sh --all
#
# The private key is generated ON the target and never moves. pistis mints a
# single-use token scoped to the requested SANs; the target redeems it. So the
# JWK provisioner password stays on pistis, and a compromised service host
# yields one certificate rather than the ability to mint any.
#
# Idempotent: re-running re-issues the certificate. Safe, but it does restart
# whatever the post-renew hook lists.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source scripts/lib.sh

PISTIS=192.168.1.55
CA_URL="https://$PISTIS:8443"
ROOT=rootca/certs/root.crt

# Every host enrolled by this repo. Keep in step with the `node` job in
# prometheus/etc/prometheus/prometheus.yml - a host here but not there is
# unmonitored, and a host there but not here will fail its scrape once
# node-exporter goes TLS.
FLEET=(
  "192.168.1.21 lenora"
  "192.168.1.50 themis"
  "192.168.1.51 delphi"
  "192.168.1.52 pythia"
  "192.168.1.53 prometheus"
  "192.168.1.54 grafana"
  "192.168.1.55 pistis"
  "192.168.1.56 loki"
  # moby carries extra addresses for the stacks it publishes; the nginx in
  # front of Home Assistant on .79 serves this certificate, so the name and
  # the address have to be in it. Words after the shortname are extra SANs.
  "192.168.1.27 moby homeassistant.home homeassistant 192.168.1.79"
  "192.168.1.60 jellyfin"
  "192.168.1.61 navidrome"
)

enrol_one() { # enrol_one <ip> <name> [extra sans...]
  local ip=$1 name=$2; shift 2
  local sans=("$name.home" "$name" "$ip" "localhost" "127.0.0.1" "$@")

  echo "== $name ($ip)"

  # step-cli is needed on the target to redeem the token and, later, to renew.
  $SSH "root@$ip" '
    set -e
    if ! command -v step >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null
      curl -fsSL -o /tmp/step-cli.deb \
        https://github.com/smallstep/cli/releases/download/v0.30.6/step-cli_0.30.6-1_amd64.deb
      dpkg -i /tmp/step-cli.deb >/dev/null && rm -f /tmp/step-cli.deb
    fi
    install -d -m 0755 /etc/homelab-tls /etc/homelab-tls/post-renew.d
    # One group for anything that must read the key. Members are added by the
    # per-service deploy scripts; node-exporter runs as prometheus everywhere.
    getent group tlscert >/dev/null || groupadd --system tlscert
  '

  # Trust anchor first: the target needs it to verify the CA before it can
  # redeem anything, and Grafana and step both read the system store.
  $SSH "root@$ip" '
    set -e
    cat > /etc/homelab-tls/root_ca.crt
    chmod 0644 /etc/homelab-tls/root_ca.crt
    cp /etc/homelab-tls/root_ca.crt /usr/local/share/ca-certificates/homelab-root-g2.crt
    update-ca-certificates >/dev/null
  ' < "$ROOT"

  # The G3 intermediate goes in the store too. Most servers here send a full
  # chain because host.crt *is* leaf+intermediate, but .NET is not one of them:
  # Jellyfin loads the PKCS#12 with X509Certificate2, which takes only the
  # first certificate, so Kestrel offered a bare leaf and every client failed
  # with "unable to verify the first certificate". With the intermediate in the
  # store, .NET builds the chain itself and sends it. Harmless elsewhere - it
  # is already trusted transitively through the root.
  $SSH "root@$ip" '
    set -e
    cat > /usr/local/share/ca-certificates/homelab-intermediate-g3.crt
    update-ca-certificates >/dev/null
  ' < intermediate/certs/intermediate-g3.crt

  # Mint a single-use token on pistis, scoped to exactly these names.
  local sanargs=() s
  for s in "${sans[@]}"; do sanargs+=(--san "$s"); done
  local token
  token=$($SSH "root@$PISTIS" \
    "step ca token '$name.home' ${sanargs[*]} \
       --provisioner admin --provisioner-password-file /etc/step-ca/secrets/jwk-password \
       --ca-url '$CA_URL' --root /etc/step-ca/certs/root_ca.crt")
  [[ -n $token ]] || { echo "   token mint failed"; return 1; }

  # Redeem on the target. Key is generated here and stays here.
  $SSH "root@$ip" "
    set -e
    umask 077
    step ca certificate '$name.home' /etc/homelab-tls/host.crt.new /etc/homelab-tls/host.key.new \
      --token '$token' --ca-url '$CA_URL' --root /etc/homelab-tls/root_ca.crt --force >/dev/null
    mv -f /etc/homelab-tls/host.crt.new /etc/homelab-tls/host.crt
    mv -f /etc/homelab-tls/host.key.new /etc/homelab-tls/host.key
    chown root:tlscert /etc/homelab-tls/host.crt /etc/homelab-tls/host.key
    chmod 0644 /etc/homelab-tls/host.crt
    chmod 0640 /etc/homelab-tls/host.key
  "

  push "$ip" fleet
  $SSH "root@$ip" '
    set -e
    systemctl daemon-reload
    systemctl enable --now homelab-tls-renew.timer >/dev/null
    for h in /etc/homelab-tls/post-renew.d/*; do [ -x "$h" ] && "$h" || true; done
  '

  echo -n "   issued: "
  $SSH "root@$ip" "openssl x509 -in /etc/homelab-tls/host.crt -noout -subject -enddate | tr '\n' ' '"
  echo
}

if [[ "${1:-}" == "--all" ]]; then
  for entry in "${FLEET[@]}"; do
    read -r ip name extra <<<"$entry"
    # shellcheck disable=SC2086  # extra is split on purpose - it is a SAN list
    enrol_one "$ip" "$name" $extra
  done
else
  [[ $# -ge 2 ]] || { echo "usage: $0 <ip> <shortname> [extra-san ...] | --all"; exit 1; }
  enrol_one "$@"
fi

echo
echo "== enrolled"
