#!/usr/bin/env bash
# Check that ruby can host mail for a domain, and give it a DKIM key. From
# ruby's clone, with sudo, after adding the domain and its mailbox in
# postfixadmin:
#
#   sudo ~/homelab/shared/ruby-mail-domain.sh <domain> <mailbox>
#
# Read-only apart from one thing: if rspamd signs from per-domain key files
# and this domain has none yet, it generates one (selector "mail", 2048-bit)
# and reloads rspamd. It prints the DNS records the domain needs, then checks
# them in public DNS, so run it again once they are published. Safe to re-run.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
[[ $# -eq 2 ]] || { echo "usage: $0 <domain> <mailbox>"; exit 1; }
DOMAIN=$1 MAILBOX=$2 SELECTOR=mail
MX=vps-5ca50660.vps.ovh.net
PUBLIC4=145.239.73.18
PUBLIC6=2001:41d0:305:2100::1:3a0e
fail=0
ok()  { echo "   $*"; }
bad() { echo "!! $*"; fail=1; }

ip -4 addr show dev dummy0 2>/dev/null | grep -q "inet 192.168.254.254/" || {
  echo "not ruby: no 192.168.254.254 on dummy0"; exit 1; }

echo "== postfix"
# Each map in the setting, asked directly: whichever backend postfixadmin
# writes to, postmap can query it.
lookup() {  # <postconf parameter> <key>
  local m
  for m in $(postconf -hx "$1" | tr ',' ' '); do
    [[ $m == *:* ]] || { [[ $m == "$2" ]] && return 0; continue; }
    postmap -q "$2" "$m" >/dev/null 2>&1 && return 0
  done
  return 1
}
lookup virtual_mailbox_domains "$DOMAIN" && ok "$DOMAIN is a mailbox domain" \
  || bad "$DOMAIN is not in virtual_mailbox_domains - add the domain in postfixadmin"
lookup virtual_mailbox_maps "$MAILBOX" && ok "$MAILBOX is a mailbox" \
  || bad "$MAILBOX is not in virtual_mailbox_maps - add the mailbox in postfixadmin"

echo "== DKIM"
txt=""
if command -v rspamadm >/dev/null; then
  dump=$(rspamadm configdump dkim_signing 2>/dev/null || true)
  path=$(sed -n 's/^[[:space:]]*path = "\(.*\)";$/\1/p' <<<"$dump" | head -1)
  if [[ $path == *'$domain'* && $path == *'$selector'* ]]; then
    key=${path//\$domain/$DOMAIN}; key=${key//\$selector/$SELECTOR}
    if [[ -s $key ]]; then
      ok "key exists: $key"
    else
      install -d -o _rspamd -g _rspamd -m 0750 "$(dirname "$key")"
      rspamadm dkim_keygen -s "$SELECTOR" -d "$DOMAIN" -b 2048 -k "$key" > "$key.dns"
      chown _rspamd:_rspamd "$key" "$key.dns"; chmod 0640 "$key"
      systemctl reload rspamd
      ok "generated $key, rspamd reloaded"
    fi
    [[ -s $key.dns ]] && txt=$(tr -d '\n\t"' < "$key.dns" | sed 's/.*( *//; s/ *).*//; s/  */ /g')
    [[ -n $txt ]] || txt=$(openssl pkey -in "$key" -pubout 2>/dev/null | sed '1d;$d' | tr -d '\n' | sed 's/^/v=DKIM1; k=rsa; p=/')
  else
    bad "rspamd does not sign from a \$domain/\$selector path - its dkim_signing is:"
    echo "$dump" | sed 's/^/     /'
  fi
elif [[ -d /etc/opendkim ]]; then
  bad "this host signs with OpenDKIM, which the script does not handle - add $DOMAIN to its KeyTable and SigningTable by hand"
else
  bad "neither rspamd nor OpenDKIM found - how does this host sign?"
fi

echo "== records to publish for $DOMAIN"
cat <<EOF
   $DOMAIN.                     A     $PUBLIC4
   $DOMAIN.                     AAAA  $PUBLIC6
   $DOMAIN.                     MX    10 $MX.
   $DOMAIN.                     TXT   "v=spf1 mx -all"
   $SELECTOR._domainkey.$DOMAIN.  TXT   "${txt:-<the DKIM key, once generated>}"
EOF

echo "== public DNS, through this host's resolver"
q() { dig +short +time=3 +tries=1 @127.0.0.1 "$@" | tr -d '"' | tr '\n' ' ' | sed 's/ $//'; }
[[ $(q "$DOMAIN" A) == "$PUBLIC4" ]] && ok "A -> $PUBLIC4" || bad "A is '$(q "$DOMAIN" A)', want $PUBLIC4"
[[ $(q "$DOMAIN" AAAA) == "$PUBLIC6" ]] && ok "AAAA -> $PUBLIC6" || bad "AAAA is '$(q "$DOMAIN" AAAA)', want $PUBLIC6"
[[ $(q "$DOMAIN" MX) == "10 $MX." ]] && ok "MX -> $MX" || bad "MX is '$(q "$DOMAIN" MX)', want 10 $MX."
q "$DOMAIN" TXT | grep -q 'v=spf1 mx -all' && ok "SPF: v=spf1 mx -all" || bad "SPF is '$(q "$DOMAIN" TXT)'"
dk=$(q "$SELECTOR._domainkey.$DOMAIN" TXT | tr -d ' ')
if [[ -n $txt && $dk == "$(tr -d ' ' <<<"$txt")" ]]; then ok "DKIM $SELECTOR._domainkey matches the key"
else bad "DKIM $SELECTOR._domainkey is '${dk:0:40}...', want the key above"; fi
dm=$(q "_dmarc.$DOMAIN" TXT)
org=${DOMAIN#*.}
[[ -n $dm ]] && ok "DMARC: $dm" || ok "DMARC: none of its own, so $org's applies: $(q "_dmarc.$org" TXT)"

echo
[[ $fail -eq 0 ]] && echo "OK" || { echo "FAIL - see !! above"; exit 1; }
