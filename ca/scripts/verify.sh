#!/usr/bin/env bash
# End-to-end smoke test of the CA, from a workstation on the LAN.
# Exit status is the number of failed checks.
#
# The issuance test runs on pistis over ssh rather than here: step-cli is not a
# workstation dependency, and issuing from the CA host proves the same thing.
PISTIS=192.168.1.55
ROOT=rootca/certs/root.crt
CA_URL="https://pistis.home:8443"
fail=0

cd "$(dirname "$0")/.."
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"
# Resolve pistis.home ourselves so this works before the DNS cutover, while
# still exercising the name the certificate is actually issued for.
CURL="curl -sS --max-time 10 --cacert $ROOT --resolve pistis.home:8443:$PISTIS"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n        got: %s\n' "$1" "$2"; fail=$((fail+1)); }
check_eq() { [[ "$3" == "$2" ]] && pass "$1" || bad "$1 (expected '$2')" "$3"; }
check_ok() { if eval "$2" >/dev/null 2>&1; then pass "$1"; else bad "$1" "command failed"; fi; }
# WARN is for a gap that is known, accepted and tracked in README.md "Not done
# yet". It is deliberately NOT counted in the exit status: a smoke test that
# can never go green stops being a gate and starts being wallpaper.
warn() { printf '  \033[33mWARN\033[0m  %s\n        %s\n' "$1" "$2"; }

echo "== the chain itself"
check_ok "G3 verifies against the G2 root" \
  "openssl verify -CAfile $ROOT intermediate/certs/intermediate-g3.crt"
check_eq "G3 subject is the one we asked for" \
  "C=FR, ST=Bouches-du-Rhone, O=Peet van de Sande, CN=Peet van de Sande Intermediate CA G3" \
  "$(openssl x509 -in intermediate/certs/intermediate-g3.crt -noout -subject | sed 's/^subject=//')"
check_eq "G3 is a CA with pathlen:0" "CA:TRUE, pathlen:0" \
  "$(openssl x509 -in intermediate/certs/intermediate-g3.crt -noout -ext basicConstraints | tail -1 | sed 's/^ *//')"
# `openssl crl` has no -checkend, and BSD and GNU date disagree on parsing
# nextUpdate, so do the comparison in python.
crl_fresh() {
  python3 - "$1" <<'CRLPY'
import subprocess, sys, datetime
out = subprocess.run(["openssl", "crl", "-in", sys.argv[1], "-noout", "-nextupdate"],
                     capture_output=True, text=True, check=True).stdout
when = datetime.datetime.strptime(out.split("=", 1)[1].strip(),
                                  "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
sys.exit(0 if when > datetime.datetime.now(datetime.timezone.utc) else 1)
CRLPY
}
check_ok "root CRL has not expired" "crl_fresh rootca/crl/root.crl"

echo "== published files, served by pistis"
for f in root.crt root.crl intermediate.crt chain.pem; do
  if curl -sS --max-time 10 -f -o /dev/null "http://$PISTIS/g3/$f"; then pass "/g3/$f is served"
  else bad "/g3/$f is served" "http error"; fi
done
check_eq "published root.crt is the real root" \
  "$(openssl x509 -in $ROOT -noout -fingerprint -sha256)" \
  "$(curl -sS --max-time 10 "http://$PISTIS/g3/root.crt" | openssl x509 -noout -fingerprint -sha256 2>/dev/null)"
echo "== the URLs frozen into the G3 certificate"
# Read them out of the certificate rather than hardcoding, so this check keeps
# telling the truth if g3-ext.cnf ever changes.
cdp=$(openssl x509 -in intermediate/certs/intermediate-g3.crt -noout -ext crlDistributionPoints \
      | grep -o 'URI:[^ ]*' | cut -d: -f2- | head -1)
aia=$(openssl x509 -in intermediate/certs/intermediate-g3.crt -noout -ext authorityInfoAccess \
      | grep -o 'URI:[^ ]*' | cut -d: -f2- | head -1)
host=$(printf '%s' "$cdp" | sed -e 's|^http://||' -e 's|/.*$||')

# 1. Split-horizon: Themis must answer with pistis, not the public VPS.
check_eq "$host resolves to pistis via Themis" "$PISTIS" \
  "$(dig +short +time=3 +tries=1 @192.168.1.50 "$host" A 2>/dev/null | tail -1)"

# 2. The files are actually served at the advertised paths. Forced at pistis,
#    so this passes before the DHCP cutover and tests the paths, not the DNS.
for u in "$cdp" "$aia"; do
  if curl -sS --max-time 10 -f -o /dev/null --resolve "$host:80:$PISTIS" "$u" 2>/dev/null; then
    pass "$u is served by pistis"
  else
    bad "$u is served by pistis" "http error"
  fi
done

# 3. What a real client on this LAN gets today. Until the router hands out
#    Themis, everything still resolves via the gateway and reaches the public
#    VPS, where nothing is published - so revocation checking is still broken
#    for real clients even though the two checks above pass.
if curl -sS --max-time 10 -f -o /dev/null "$cdp" 2>/dev/null; then
  pass "$cdp reachable as this host actually resolves it"
else
  warn "$cdp is NOT reachable as this host actually resolves it" \
    "expected until the DHCP cutover to Themis - see README.md"
fi

echo "== step-ca"
check_eq "health endpoint" '{"status":"ok"}' "$($CURL "$CA_URL/health" 2>/dev/null | tr -d '[:space:]')"
# Serving TLS off the G3 chain is the first real proof the key and cert match.
check_ok "step-ca serves TLS that verifies against our own root" \
  "$CURL -o /dev/null '$CA_URL/health'"
provs=$($CURL "$CA_URL/provisioners" 2>/dev/null)
for p in admin acme; do
  echo "$provs" | grep -q "\"$p\"" && pass "provisioner '$p' present" \
    || bad "provisioner '$p' present" "not in /provisioners"
done
check_ok "ACME directory is up" \
  "$CURL -f -o /dev/null '$CA_URL/acme/acme/directory'"

echo "== end-to-end issuance (on pistis, JWK provisioner)"
issue=$($SSH "root@$PISTIS" '
  set -e
  d=$(mktemp -d); trap "rm -rf $d" EXIT
  step ca certificate verify-probe.home "$d/c.crt" "$d/c.key" \
    --provisioner admin --provisioner-password-file /etc/step-ca/secrets/jwk-password \
    --ca-url https://pistis.home:8443 --root /etc/step-ca/certs/root_ca.crt \
    --not-after 5m --force >/dev/null 2>&1
  openssl verify -CAfile /etc/step-ca/certs/root_ca.crt \
    -untrusted /etc/step-ca/certs/intermediate_ca.crt "$d/c.crt" >/dev/null
  openssl x509 -in "$d/c.crt" -noout -issuer | sed "s/^issuer=//"
' 2>&1)
check_eq "a leaf issues and chains to the root" \
  "C=FR, ST=Bouches-du-Rhone, O=Peet van de Sande, CN=Peet van de Sande Intermediate CA G3" \
  "$issue"

echo "== monitoring"
if nc -z -G 2 "$PISTIS" 9100 2>/dev/null; then pass "node_exporter listening on $PISTIS:9100"
else bad "node_exporter listening on $PISTIS:9100" "port closed"; fi
# https, because Prometheus now serves its own API off this CA. Verified
# against our root rather than the system store - if this ever silently falls
# back to plain HTTP it should fail, not quietly succeed.
if curl -sS --max-time 10 --cacert "$ROOT" "https://192.168.1.53:9090/api/v1/targets" \
   | tr ',' '\n' | grep -q "$PISTIS:9100"; then
  pass "prometheus has a target for $PISTIS"
else
  bad "prometheus has a target for $PISTIS" "not in /api/v1/targets"
fi

echo "== survives a cold boot (binding to a static IP is the usual failure)"
check_ok "step-ca is enabled at boot" "$SSH root@$PISTIS 'systemctl is-enabled --quiet step-ca'"
check_ok "nginx is enabled at boot"  "$SSH root@$PISTIS 'systemctl is-enabled --quiet nginx'"

echo
if (( fail )); then echo "$fail check(s) failed"; else echo "all checks passed"; fi
exit $fail
