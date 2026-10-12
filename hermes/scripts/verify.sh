#!/usr/bin/env bash
# Checks the intent of hermes/: a mailcow that serves webmail and mail off the
# lab CA, relays for the labs and nobody else, sends nothing out by default,
# and is monitored and logged. Read-only - SMTP checks stop at RCPT TO.
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.8.57
LENORA=192.168.8.21
PROM=192.168.8.53
LOKI=192.168.8.56
CURL="curl -sS --max-time 10 --cacert $CA_ROOT"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"

# rcpt <addr> <to>: the SMTP reply code to RCPT TO, without sending anything.
# The sender's domain must resolve publicly: mailcow's unbound recurses from
# the root, knows nothing of .home, and would 450 an unknown sender domain
# before the relay check is ever reached.
RCPT_PY='
import smtplib, sys
s = smtplib.SMTP(sys.argv[1], 25, timeout=15)
s.ehlo("verify.home"); s.mail("verify@gmail.com")
print(s.rcpt(sys.argv[2])[0]); s.rset(); s.quit()'

echo "== VM"
$SSH "root@$LENORA" 'qm config 109 | grep -q "^onboot: 1"' 2>/dev/null \
  && pass "VM 109 starts at boot" || bad "VM 109 starts at boot" "onboot is not 1"
$SSH "root@$LENORA" 'qm agent 109 ping' 2>/dev/null \
  && pass "guest agent answers" || bad "guest agent answers" "qm agent 109 ping failed"

echo "== mailcow containers"
# The same view Prometheus gets, from the textfile collector.
down=$($SSH "root@$HOST" 'grep " 0$" /var/lib/node_exporter/textfile/mailcow.prom' 2>/dev/null)
n=$($SSH "root@$HOST" 'grep -c "^mailcow_container_up" /var/lib/node_exporter/textfile/mailcow.prom' 2>/dev/null || echo 0)
if [[ ${n:-0} -gt 10 && -z $down ]]; then pass "all $n mailcow containers up and not unhealthy"
else bad "all mailcow containers up" "${down:-only ${n:-0} containers reported}"; fi
for kv in SKIP_CLAMD=y SKIP_FTS=y SKIP_LETS_ENCRYPT=y SKIP_SOGO=n ENABLE_IPV6=true; do
  $SSH "root@$HOST" "grep -qx '$kv' /opt/mailcow-dockerized/mailcow.conf" 2>/dev/null \
    && pass "mailcow.conf has $kv" || bad "mailcow.conf has $kv" "override not applied - run deploy.sh"
done

echo "== TLS"
https_ok "mailcow UI on $HOST:443" "https://$HOST/"
https_ok "SOGo webmail" "https://$HOST/SOGo/"
chain_ok "hermes:443" "$HOST:443"
chain_ok "hermes:993 (IMAPS)" "$HOST:993"
chain_ok "hermes:465 (SMTPS)" "$HOST:465"
out=$(echo | openssl s_client -starttls smtp -connect "$HOST:25" -CAfile "$CA_ROOT" 2>/dev/null)
grep -q "Verify return code: 0 (ok)" <<<"$out" \
  && pass "hermes:25 STARTTLS verifies against the G2 root" \
  || bad "hermes:25 STARTTLS verifies" "$(grep -m1 'Verify return code' <<<"$out" || echo 'no handshake')"
renewal_ok hermes "$HOST"

echo "== relay policy"
# lenora is in mynetworks (it stands in for SNAT'd lab zones), so it may relay;
# default_transport then bounces what it relays, which this does not exercise.
code=$($SSH "root@$LENORA" "python3 -c '$RCPT_PY' $HOST someone@example.com" 2>/dev/null)
[[ $code == 250 ]] && pass "lenora (mynetworks) may relay (RCPT=250)" \
  || bad "lenora (mynetworks) may relay" "RCPT=${code:-no answer}"
# The workstation is on the LAN but not in mynetworks: it must be refused, over
# IPv6 as well. A broken Docker IPv6 setup shows LAN clients to postfix as the
# Docker gateway, which IS in mynetworks - that is how mailcow becomes an open
# relay, and why this is checked on both families.
v6=$($SSH "root@$HOST" "ip -6 -o addr show scope global dev eth0 | grep -v temporary | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null)
for a in "$HOST" ${v6:+"$v6"}; do
  code=$(python3 -c "$RCPT_PY" "$a" someone@example.com 2>/dev/null)
  # mailcow uses defer_unauth_destination, so "Relay access denied" is a 454.
  [[ $code == 454 || $code == 554 ]] && pass "relay from the LAN refused via $a (RCPT=$code)" \
    || bad "relay from the LAN refused via $a" "RCPT=${code:-no answer}"
done
[[ -n $v6 ]] || bad "hermes has a global IPv6 address" "none on eth0 - is SLAAC working?"

echo "== node-exporter"
https_ok "node-exporter on $HOST:9100" "https://$HOST:9100/metrics"
$CURL "https://$HOST:9100/metrics" 2>/dev/null | grep -q '^mailcow_container_up' \
  && pass "mailcow_container_up is exported" \
  || bad "mailcow_container_up is exported" "textfile timer not running?"

echo "== scraped by prometheus"
for job in node alloy; do
  $CURL "https://$PROM:9090/api/v1/targets" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
ok=[t for t in d['data']['activeTargets']
    if t['labels']['job']=='$job' and t['labels'].get('role')=='hermes'
    and t['health']=='up']
sys.exit(0 if ok else 1)" \
    && pass "prometheus $job target for hermes is up" \
    || bad "prometheus $job target for hermes is up" "no healthy target - deploy prometheus/ or wait a scrape interval"
done

echo "== logs in loki"
n=$($CURL -G "https://$LOKI:3100/loki/api/v1/query" \
      --data-urlencode 'query=count_over_time({host="hermes", container=~".+mailcow.+"}[15m])' 2>/dev/null \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(sum(int(v["value"][1]) for v in r))' 2>/dev/null || echo 0)
[[ ${n:-0} -gt 0 ]] && pass "loki has mailcow container lines for hermes ($n in 15m)" \
  || bad "loki has mailcow container lines for hermes" "nothing in 15m - is alloy up, and the engine on journald?"

echo
[[ $fail -eq 0 ]] && echo "all checks passed" || { echo "$fail check(s) failed"; exit 1; }
