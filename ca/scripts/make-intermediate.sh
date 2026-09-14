#!/usr/bin/env bash
# Create the G3 intermediate CA: key, CSR, and a certificate signed by the
# offline G2 root in rootca/.
#
# Runs entirely on the workstation. The root key never leaves this machine and
# is never copied to pistis - only the signed intermediate and its own key are.
# You will be prompted for the G2 root key passphrase; it is not stored.
#
# Idempotent: refuses to re-sign if intermediate/certs/intermediate-g3.crt
# already exists. Pass --force to mint a replacement (the old one stays valid
# in the root's index.txt until you revoke it).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOTCA="$PWD/rootca"
INT="$PWD/intermediate"

SUBJ="/C=FR/ST=Bouches-du-Rhone/O=Peet van de Sande/CN=Peet van de Sande Intermediate CA G3"
DAYS=3652   # ~10 years, matching the g2 intermediate; the root runs to 2046

KEY="$INT/private/intermediate-g3.key"
CSR="$INT/csr/intermediate-g3.csr"
CRT="$INT/certs/intermediate-g3.crt"
CHAIN="$INT/certs/chain-g3.pem"

force=0
[[ "${1:-}" == "--force" ]] && force=1

if [[ -f "$CRT" && $force -eq 0 ]]; then
  echo "== $CRT exists already - nothing to do"
  openssl x509 -in "$CRT" -noout -subject -issuer -dates
  exit 0
fi

[[ -f secrets.env ]] || { echo "secrets.env missing - see README.md"; exit 1; }
# shellcheck disable=SC1091
source secrets.env
: "${STEP_CA_KEY_PASSWORD:?not set in secrets.env}"
# openssl reads this out of the environment (-passin/-passout env:), and
# sourcing a file does not export. Without this it fails at key generation.
export STEP_CA_KEY_PASSWORD

umask 077
mkdir -p "$INT/private" "$INT/csr" "$INT/certs"
chmod 700 "$INT/private"

# The root config was written for /home/peet/ca.g2/root and still says so. It
# is a record of how the g2 root was run, so rewrite `dir` into a throwaway
# copy rather than editing the original.
WORKCNF="$(mktemp -t rootca-cnf.XXXXXX)"
trap 'rm -f "$WORKCNF"' EXIT
sed -e "s|^dir *=.*|dir = $ROOTCA|" "$ROOTCA/openssl.cnf" > "$WORKCNF"

# ------------------------------------------------------------------ key ----
# ECDSA P-256 under an RSA-4096 root. Mixed chains verify fine everywhere, and
# P-256 is what step-ca signs with natively.
if [[ -f "$KEY" && $force -eq 0 ]]; then
  echo "== reusing existing key $KEY"
else
  echo "== generating ECDSA P-256 intermediate key"
  openssl ecparam -name prime256v1 -genkey -noout \
    | openssl pkcs8 -topk8 -v2 aes-256-cbc \
        -passout env:STEP_CA_KEY_PASSWORD -out "$KEY"
  chmod 600 "$KEY"
fi

# ------------------------------------------------------------------ csr ----
echo "== generating CSR"
echo "   $SUBJ"
openssl req -new -key "$KEY" -passin env:STEP_CA_KEY_PASSWORD \
  -sha256 -subj "$SUBJ" -out "$CSR"

# ----------------------------------------------------------------- sign ----
# -policy policy_loose: the root's default policy_strict requires country and
# state to MATCH the root's own (GB/England). This intermediate is deliberately
# FR/Bouches-du-Rhone, so strict matching would refuse it. Loose still requires
# a commonName and changes nothing about what the certificate can do.
echo "== signing with the G2 root (enter the root key passphrase)"
openssl ca -config "$WORKCNF" \
  -policy policy_loose \
  -extfile "$INT/g3-ext.cnf" -extensions v3_intermediate_ca_g3 \
  -days "$DAYS" -notext -md sha256 -batch \
  -in "$CSR" -out "$CRT"
chmod 644 "$CRT"

# ---------------------------------------------------------------- chain ----
cat "$CRT" "$ROOTCA/certs/root.crt" > "$CHAIN"
chmod 644 "$CHAIN"

echo "== verifying"
openssl verify -CAfile "$ROOTCA/certs/root.crt" "$CRT"
openssl x509 -in "$CRT" -noout -subject -issuer -dates \
  -ext basicConstraints,keyUsage,crlDistributionPoints,authorityInfoAccess

# The CDP stamped above is only useful if the CRL behind it is current, and
# the passphrase is already in the operator's head at this point - so do it now
# rather than leaving a dangling URL.
echo
"$PWD/scripts/root-crl.sh"

echo
echo "== done - intermediate/certs/intermediate-g3.crt"
echo "   next: scripts/deploy.sh"
