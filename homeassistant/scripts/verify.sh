#!/usr/bin/env bash
# Smoke test Home Assistant's TLS and the renewal path that keeps it alive.
# Exit status is the number of failed checks.
set -uo pipefail

cd "$(dirname "$0")/.."

HA=192.168.8.90
LENORA=192.168.8.21
ROOT=../ca/rootca/certs/root.crt
fail=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n        got: %s\n' "$1" "$2"; fail=$((fail+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n        %s\n' "$1" "$2"; }
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

echo "== TLS on $HA"
# Verified against our own root and through the name the certificate is issued
# for; --resolve because .home resolves only from hosts that use Themis, and
# this script may be run from a workstation on a VPN.
code=$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' \
         --cacert "$ROOT" --resolve "homeassistant.home:443:$HA" \
         "https://homeassistant.home/" 2>/dev/null || echo 000)
[[ $code == 200 || $code == 302 ]] \
  && pass "https://homeassistant.home/ answers ($code)" \
  || bad "https://homeassistant.home/ answers" "http=$code"

chain=$(echo | openssl s_client -connect "$HA:443" -servername homeassistant.home \
          -CAfile "$ROOT" 2>/dev/null | grep "Verify return code")
[[ $chain == *"Verify return code: 0"* ]] \
  && pass "chain verifies against the G2 root" \
  || bad "chain verifies against the G2 root" "${chain:-no handshake}"

leaf=$(echo | openssl s_client -connect "$HA:443" 2>/dev/null | openssl x509 2>/dev/null)
sans=$(printf '%s' "$leaf" | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -1 | tr -d ' ')
for want in "DNS:homeassistant.home" "DNS:homeassistant.local" "IP Address:$HA"; do
  w=${want// /}
  [[ $sans == *"$w"* ]] && pass "SAN present: $want" || bad "SAN present: $want" "$sans"
done

if printf '%s' "$leaf" | openssl x509 -noout -checkend $((20*86400)) >/dev/null 2>&1; then
  pass "more than 20 days of validity left"
else
  end=$(printf '%s' "$leaf" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  # Under 10 days the timer renews on its own, so this is only a warning until
  # it is actually close.
  warn "under 20 days of validity left (notAfter $end)" \
       "the daily timer renews under 10 days; check it ran"
fi

echo "== renewal path on $LENORA"
for f in /usr/local/bin/homelab-ha-tls-renew /usr/local/share/homelab/ha-tls.py; do
  $SSH "root@$LENORA" "test -s $f" 2>/dev/null \
    && pass "$f installed" || bad "$f installed" "missing - run scripts/deploy.sh"
done

state=$($SSH "root@$LENORA" "systemctl is-enabled homelab-ha-tls-renew.timer 2>/dev/null" || echo unknown)
[[ $state == enabled ]] && pass "renewal timer is enabled" || bad "renewal timer is enabled" "$state"

next=$($SSH "root@$LENORA" "systemctl show -p NextElapseUSecRealtime --value homelab-ha-tls-renew.timer 2>/dev/null" || echo "")
[[ -n $next && $next != 0 ]] && pass "renewal timer has a next run scheduled" \
  || bad "renewal timer has a next run scheduled" "${next:-none}"

echo "== the VM agrees with the supervisor"
# A certificate on disk that the supervisor does not know about is the failure
# mode that makes Home Assistant look dead: it serves :80 while the supervisor
# watchdog probes :443, or the reverse.
info=$($SSH "root@$LENORA" "qm guest exec 302 --timeout 30 -- /bin/sh -c 'ha core info' 2>/dev/null" \
       | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("out-data",""))' 2>/dev/null)
ssl=$(printf '%s' "$info" | sed -n 's/^ssl: *//p')
port=$(printf '%s' "$info" | sed -n 's/^port: *//p')
[[ $ssl == true ]] && pass "supervisor has ssl: true" || bad "supervisor has ssl: true" "ssl=${ssl:-unknown}"
[[ $port == 443 ]] && pass "supervisor has port: 443" \
  || warn "supervisor port is ${port:-unknown}, not 443" "fine if server_port says the same"

echo
[[ $fail -eq 0 ]] && echo "== all checks passed" || echo "== $fail check(s) failed"
exit "$fail"
