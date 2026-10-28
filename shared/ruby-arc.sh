#!/usr/bin/env bash
# ARC-seal the mail ruby forwards, such as an alias pointing at another
# provider. From ruby's clone, with sudo:
#
#   sudo ~/homelab/shared/ruby-arc.sh
#
# A forwarded message still carries its original sender, so SPF fails at the
# next hop, and anything that alters it on the way breaks the original DKIM
# signature. The ARC seal records that SPF, DKIM and DMARC passed when the
# mail reached ruby, signed for the domain it was addressed to.
#
# The seal reuses rspamd's DKIM keys and selector, so it needs no new DNS
# records. Writes /etc/rspamd/local.d/arc.conf (keeping any earlier one
# beside it) and reloads rspamd. Safe to re-run.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
ip -4 addr show dev dummy0 2>/dev/null | grep -q "inet 192.168.254.254/" || {
  echo "not ruby: no 192.168.254.254 on dummy0"; exit 1; }
CONF=/etc/rspamd/local.d/arc.conf
fail=0
ok()  { echo "   $*"; }
bad() { echo "!! $*"; fail=1; }

echo "== postfix"
# Forwarded mail arrives on :25, so rspamd has to see that listener's mail.
milters=$(postconf -h smtpd_milters)
override=$(postconf -hP 'smtp/inet/smtpd_milters' 2>/dev/null || true)
if [[ -n $override ]]; then
  [[ $override == *rspamd* ]] && ok ":25 uses rspamd ($override)" \
    || bad ":25 overrides smtpd_milters without rspamd: $override"
else
  [[ $milters == *rspamd* ]] && ok ":25 uses rspamd ($milters)" \
    || bad "smtpd_milters has no rspamd ('$milters') - ARC cannot seal mail arriving on :25"
fi

echo "== keys"
dump=$(rspamadm configdump dkim_signing 2>/dev/null)
path=$(sed -n 's/^[[:space:]]*path = "\(.*\)";$/\1/p' <<<"$dump" | head -1)
sel=$(sed -n 's/^[[:space:]]*selector = "\(.*\)";$/\1/p' <<<"$dump" | head -1)
[[ $path == *'$domain'* && -n $sel ]] || {
  echo '!! rspamd does not sign from a per-domain ($domain) path - its dkim_signing is:'
  sed 's/^/     /' <<<"$dump"; exit 1; }
ok "DKIM keys: $path, selector $sel"
for k in "${path%/*}"/*.key; do
  [[ -e $k ]] && ok "key for $(basename "${k%.key}")"
done

echo "== rspamd arc"
new=$(mktemp)
cat > "$new" <<EOF
# Seal with the DKIM keys and selector, so ARC needs no DNS records of its
# own. The sealing domain is the full domain, as for DKIM signing.
path = "$path";
selector = "$sel";
use_esld = false;
# Mail arriving from outside, such as an alias forwarding elsewhere, is sealed
# for the domain it was addressed to.
sign_inbound = true;
use_domain_sign_inbound = "recipient";
EOF
if [[ -f $CONF ]] && cmp -s "$new" "$CONF"; then
  ok "$CONF is current"; rm -f "$new"
else
  [[ -f $CONF ]] && { cp -p "$CONF" "$CONF.$(date +%F-%H%M%S)"; ok "kept the earlier $CONF beside it"; }
  install -m 0644 "$new" "$CONF"; rm -f "$new"
  if rspamadm configtest >/dev/null; then
    systemctl reload rspamd; ok "wrote $CONF, rspamd reloaded"
  else
    bad "rspamadm configtest failed with the new $CONF:"; rspamadm configtest | sed 's/^/     /'
    exit 1
  fi
fi
rspamadm configdump arc 2>/dev/null | grep -E '^\s*(path|selector|use_esld|sign_inbound|use_domain_sign_inbound) =' | sed 's/^ */   arc: /'

echo "== SRS"
# ARC only helps where the next hop honours ruby's seal. Rewriting the
# envelope sender on forwarded mail makes SPF pass outright.
if systemctl is-active -q postsrsd 2>/dev/null \
   || postconf -h sender_canonical_maps recipient_canonical_maps | grep -qi srs; then
  ok "SRS is in use"
else
  ok "no SRS: forwarded mail keeps its original sender, so SPF fails at the next hop"
fi

echo
[[ $fail -eq 0 ]] && echo "OK - send a test to a forwarding alias and look for ARC-Seal: i=1; ... d=<its domain>" \
  || { echo "FAIL - see !! above"; exit 1; }
