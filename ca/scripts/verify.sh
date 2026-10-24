#!/usr/bin/env bash
# End-to-end smoke test of the CA, from a workstation on the LAN.
# Exit status is the number of failed checks.
#
# The issuance test runs on pistis over ssh rather than here: step-cli is not a
# workstation dependency, and issuing from the CA host proves the same thing.
PISTIS=192.168.8.55
ROOT=rootca/certs/root.crt
CA_URL="https://pistis.home:8443"
fail=0

cd "$(dirname "$0")/.."
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"
# Resolve pistis.home ourselves rather than trusting whatever resolver this
# workstation has - it may be on a VPN - while still exercising the name the
# certificate is actually issued for.
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
  "$(dig +short +time=3 +tries=1 @192.168.8.50 "$host" A 2>/dev/null | tail -1)"

# 2. The files are actually served at the advertised paths. Forced at pistis,
#    so this tests the paths rather than whatever DNS the workstation has.
for u in "$cdp" "$aia"; do
  if curl -sS --max-time 10 -f -o /dev/null --resolve "$host:80:$PISTIS" "$u" 2>/dev/null; then
    pass "$u is served by pistis"
  else
    bad "$u is served by pistis" "http error"
  fi
done

# 3. What this host gets with its own resolver, whatever that resolves to.
#    Both answers now serve the files: Themis says pistis, and the public
#    answer is ruby, which proxies back to pistis. So a failure here is this
#    workstation's connectivity rather than the lab's config, which is why it
#    stays a WARN - check 4 is the one that tests ruby on purpose.
if curl -sS --max-time 10 -f -o /dev/null "$cdp" 2>/dev/null; then
  pass "$cdp reachable as this host actually resolves it"
else
  warn "$cdp is NOT reachable as this host actually resolves it" \
    "neither pistis nor ruby answered for the address this host resolved - a \
fact about this workstation, not the lab"
fi

# 4. The public path, through ruby. ca.peetvandesande.com is a CNAME to ruby
#    (145.239.73.18), which proxies /g3/ to pistis over wg1 and serves /g2/
#    statically - ca/ruby/, installed by scripts/install-ruby.sh. --resolve
#    pins the address so this tests ruby rather than whatever this
#    workstation's resolver says; the lab answers the same name with pistis.
#
#    /g2/root.crl is only ever served here, pistis being a G3 host, so this is
#    the only check that covers the CDP of serials 1000-1002 at all.
RUBY=145.239.73.18
for u in "$cdp" "$aia" "http://$host/g2/root.crl"; do
  if curl -sS --max-time 15 -f -o /dev/null --resolve "$host:80:$RUBY" "$u" 2>/dev/null; then
    pass "$u is served publicly by ruby"
  else
    bad "$u is served publicly by ruby" \
      "http error - run ca/scripts/install-ruby.sh on ruby, or check wg1"
  fi
done

# 5. ruby's /g2/root.crl is a static copy, not a proxy, so it is the one
#    published file that can go stale. install-ruby.sh installs it from the
#    clone's rootca/crl/root.crl, so compare against this repo's copy - a
#    mismatch means root-crl.sh has run since ruby was last updated.
check_eq "ruby's /g2/root.crl matches rootca/crl/root.crl" \
  "$(shasum -a 256 < rootca/crl/root.crl | cut -d' ' -f1)" \
  "$(curl -sS --max-time 15 --resolve "$host:80:$RUBY" "http://$host/g2/root.crl" \
     2>/dev/null | shasum -a 256 | cut -d' ' -f1)"

echo "== step-ca"
check_eq "health endpoint" '{"status":"ok"}' "$($CURL "$CA_URL/health" 2>/dev/null | tr -d '[:space:]')"
# step-ca binds [::]:8443, so it answers over IPv6 as well - `address` takes
# one value, and a wildcard is the only way to serve both families. Pinned to
# the ULA so this tests the v6 listener rather than whichever family the
# resolver happened to prefer; the name is still what the certificate is
# verified against.
PISTIS6=fd33:5692:1834:1000:be24:11ff:fe04:f703
check_ok "step-ca answers on its ULA, with a certificate that verifies" \
  "curl -sS --max-time 10 --cacert $ROOT --resolve 'pistis.home:8443:[$PISTIS6]' \
     -f -o /dev/null '$CA_URL/health'"
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
if curl -sS --max-time 10 --cacert "$ROOT" "https://192.168.8.53:9090/api/v1/targets" \
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
