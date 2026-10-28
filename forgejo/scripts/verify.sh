#!/usr/bin/env bash
# Checks the intent of forgejo/: Forgejo on HTTPS off the lab CA over both
# families, one URL that works on the LAN and from outside, git over SSH
# through OpenSSH, and the host monitored like the rest of the fleet.
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.8.62
NAME=git.peetvandesande.com
RUBY4=145.239.73.18
PROM=192.168.8.53
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"

echo "== addresses"
ula=$($SSH "root@$HOST" "ip -6 addr show dev eth0 scope global -tentative | grep -oE 'fd33:5692:1834:1000:[0-9a-f:]+' | head -1" 2>/dev/null)
gua=$($SSH "root@$HOST" "ip -6 addr show dev eth0 scope global -tentative | grep -v ' temporary' | grep -oE 'inet6 2[0-9a-f:]+' | head -1" 2>/dev/null)
[[ -n $ula ]] && pass "ULA $ula" || bad "forgejo holds a ULA" "none - is the RA reaching it?"
[[ -n $gua ]] && pass "GUA ${gua#inet6 }" || bad "forgejo holds a GUA" "none"
$SSH "root@$HOST" 'ping -6 -c1 -W3 2606:4700:4700::1111 >/dev/null' 2>/dev/null \
  && pass "reaches the internet over IPv6" || bad "reaches the internet over IPv6" "ping -6 failed"
$SSH "root@$HOST" 'systemctl is-active --quiet networking' 2>/dev/null \
  && pass "networking.service is active (not wedged on dhclient -6)" \
  || bad "networking.service is active" "see ../CLAUDE.md on ip6=auto"

echo "== HTTPS, by name, over both families"
https_ok "forgejo.home" "https://forgejo.home/"
https_ok "$NAME (split-horizon to $HOST)" "https://$NAME/"
code=$(curl -6 -sS --max-time 10 --cacert "$CA_ROOT" -o /dev/null -w '%{http_code}' "https://$NAME/" 2>/dev/null) || code=000
[[ $code == 200 ]] && pass "$NAME over IPv6 (200)" || bad "$NAME over IPv6" "http=$code"
chain_ok "forgejo:443" "$HOST:443"
renewal_ok forgejo "$HOST"
loc=$(curl -sS --max-time 8 -o /dev/null -w '%{redirect_url}' "http://$HOST/" 2>/dev/null)
[[ $loc == "https://$NAME/" ]] && pass ":80 redirects to https://$NAME/" \
  || bad ":80 redirects to https://$NAME/" "redirects to ${loc:-nothing}"

echo "== split-horizon"
for t in A AAAA; do
  got=$(dig +short "$NAME" $t | tail -1)
  case $t in
    A)    want=$HOST ;;
    AAAA) want=$ula ;;
  esac
  [[ -n $want && $got == "$want" ]] && pass "$NAME $t is forgejo ($got)" \
    || bad "$NAME $t is forgejo" "got ${got:-nothing}, want $want - dns/CLAUDE.md invariant 5"
done

echo "== settings that must not drift"
# Running config, not the file - what Forgejo actually loaded.
for kv in "service DISABLE_REGISTRATION true" "security INSTALL_LOCK true" "server ROOT_URL https://$NAME/"; do
  set -- $kv
  got=$($SSH "root@$HOST" "awk -F' *= *' '/^\[/{s=\$0} s==\"[$1]\" && \$1==\"$2\"{print \$2}' /etc/forgejo/app.ini" 2>/dev/null)
  [[ $got == "$3" ]] && pass "[$1] $2 = $3" || bad "[$1] $2 = $3" "got: ${got:-unset}"
done
# Forgejo must not be able to rewrite its own config.
mode=$($SSH "root@$HOST" 'stat -c "%U:%G %a" /etc/forgejo/app.ini' 2>/dev/null)
[[ $mode == "root:git 640" ]] && pass "app.ini is root:git 0640" || bad "app.ini is root:git 0640" "$mode"

echo "== git over SSH"
# A refused key is the pass: it proves sshd asked Forgejo (AuthorizedKeysCommand)
# rather than falling back to a password or a stale authorized_keys.
out=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      -o IdentitiesOnly=yes -o IdentityFile=/dev/null "git@$HOST" 2>&1)
grep -q 'Permission denied (publickey)' <<<"$out" && pass "sshd offers git publickey only" \
  || bad "sshd offers git publickey only" "$out"
$SSH "root@$HOST" 'sshd -T -C user=git,host=x,addr=127.0.0.1 2>/dev/null | grep -q "^authorizedkeyscommand /usr/local/bin/forgejo keys"' \
  && pass "sshd asks forgejo for git's keys" || bad "sshd asks forgejo for git's keys" "Match User git block not in effect"

echo "== public side, through ruby"
# Pinned to ruby's public address: by name this would resolve to forgejo.
code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' --resolve "$NAME:443:$RUBY4" "https://$NAME/" 2>/dev/null) || code=000
[[ $code == 200 ]] && pass "https://$NAME/ via ruby (200, public certificate)" \
  || bad "https://$NAME/ via ruby" "http=$code - is forgejo/scripts/install-ruby.sh installed on ruby?"
code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' --resolve "$NAME:443:$RUBY4" "https://$NAME/metrics" 2>/dev/null) || code=000
[[ $code == 404 ]] && pass "/metrics is not served via ruby (404)" || bad "/metrics is not served via ruby" "http=$code"
# ruby's public :22 is forgejo's sshd, end to end: same host key as on the LAN.
want=$(ssh-keyscan -T 5 -t ed25519 "$HOST" 2>/dev/null | awk '{print $3}')
got=$(ssh-keyscan -T 8 -t ed25519 "$RUBY4" 2>/dev/null | awk '{print $3}')
[[ -n $want && $got == "$want" ]] && pass "ruby :22 is forgejo's sshd (host key matches)" \
  || bad "ruby :22 is forgejo's sshd" "${got:+another host key - the sshd of ruby itself is public}${got:-nothing} - forgejo/scripts/install-ruby-ssh.sh"

echo "== monitored"
for job in node alloy forgejo; do
  curl -sS --max-time 10 --cacert "$CA_ROOT" "https://$PROM:9090/api/v1/targets" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
ok=[t for t in d['data']['activeTargets']
    if t['labels']['job']=='$job' and t['labels'].get('role')=='forgejo' and t['health']=='up']
sys.exit(0 if ok else 1)" \
    && pass "prometheus $job target for forgejo is up" \
    || bad "prometheus $job target for forgejo is up" "deploy prometheus/ or wait a scrape interval"
done

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
