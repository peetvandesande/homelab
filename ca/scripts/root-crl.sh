#!/usr/bin/env bash
# Regenerate the G2 root's CRL - the file the G3 intermediate's
# crlDistributionPoints points at.
#
# The one in the repo expired on 18 Jan 2017. A CDP naming an expired CRL is
# worse than no CDP at all: clients that fetch and honour it treat the whole
# chain as unverifiable. So this has to be current before anything trusts G3.
#
# Runs on the workstation and prompts for the root key passphrase. Also run it
# after `openssl ca -revoke` on anything the root signed, then re-deploy so
# nginx on pistis serves the new file.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOTCA="$PWD/rootca"

# 10 years. An offline root that is opened once a decade cannot honour a
# 30-day CRL, and a stale CRL fails closed. The trade is real: a revocation
# only reaches clients when this is regenerated and re-deployed by hand.
CRL_DAYS=3650

WORKCNF="$(mktemp -t rootca-cnf.XXXXXX)"
trap 'rm -f "$WORKCNF"' EXIT
sed -e "s|^dir *=.*|dir = $ROOTCA|" "$ROOTCA/openssl.cnf" > "$WORKCNF"

echo "== regenerating root CRL (enter the root key passphrase)"
openssl ca -config "$WORKCNF" -gencrl -crldays "$CRL_DAYS" -out "$ROOTCA/crl/root.crl"

openssl crl -in "$ROOTCA/crl/root.crl" -noout -lastupdate -nextupdate -issuer
echo "== ok - re-run scripts/deploy.sh to publish it"
