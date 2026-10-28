#!/usr/bin/env bash
# SRS on ruby: rewrite the envelope sender of mail ruby forwards elsewhere, so
# SPF at the next hop checks ruby's own domain rather than the original
# sender's. From ruby's clone, with sudo:
#
#   sudo ~/homelab/shared/ruby-srs.sh
#
# Installs postsrsd, makes peetvandesande.com its SRS domain and exempts every
# domain ruby holds a DKIM key for, so mail from ruby's own domains keeps its
# sender. Re-run after adding a domain. Bounces to an SRS address are mapped
# back to the original sender. Keeps a dated copy of each file it changes.
# Safe to re-run.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
ip -4 addr show dev dummy0 2>/dev/null | grep -q "inet 192.168.254.254/" || {
  echo "not ruby: no 192.168.254.254 on dummy0"; exit 1; }
SRS_DOMAIN=peetvandesande.com
stamp=$(date +%F-%H%M%S)
ok() { echo "   $*"; }
die() { echo "!! $*"; exit 1; }
keep() { [[ -f $1 && ! -f $1.$stamp ]] && cp -p "$1" "$1.$stamp" && ok "kept $1.$stamp"; return 0; }

echo "== own domains"
# The domains ruby signs for are the domains it sends as.
dump=$(rspamadm configdump dkim_signing 2>/dev/null)
path=$(sed -n 's/^[[:space:]]*path = "\(.*\)";$/\1/p' <<<"$dump" | head -1)
sel=$(sed -n 's/^[[:space:]]*selector = "\(.*\)";$/\1/p' <<<"$dump" | head -1)
[[ $path == *'$domain'* ]] || die "rspamd's DKIM key path has no \$domain: '$path'"
base=${path##*/}; base=${base//\$selector/$sel}
pre=${base%%\$domain*}; suf=${base#*\$domain}
domains=("$SRS_DOMAIN")
for k in "${path%/*}"/*; do
  n=${k##*/}; [[ $n == "$pre"*"$suf" ]] || continue
  d=${n#"$pre"}; d=${d%"$suf"}
  [[ $d == "$SRS_DOMAIN" || $d == *[!a-z0-9.-]* ]] || domains+=("$d")
done
ok "SRS domain $SRS_DOMAIN; not rewritten: ${domains[*]}"

echo "== postsrsd"
dpkg -s postsrsd >/dev/null 2>&1 || { apt-get install -y -q postsrsd >/dev/null; ok "installed postsrsd"; }
ok "version $(dpkg-query -W -f '${Version}' postsrsd)"
if [[ -f /etc/postsrsd.conf ]]; then
  # postsrsd 2: one socketmap, on loopback TCP so Postfix's chrooted cleanup
  # reaches it.
  conf=/etc/postsrsd.conf
  set_conf() {  # <key> <value>, replacing an active or commented-out line
    if grep -Eq "^[#[:space:]]*$1[[:space:]]*=" "$conf"; then
      sed -i -E "0,/^[#[:space:]]*$1[[:space:]]*=.*/s||$1 = $2|" "$conf"
    else
      printf '%s = %s\n' "$1" "$2" >> "$conf"
    fi
  }
  list=$(printf '"%s",' "${domains[@]}"); list="{${list%,}}"
  want=$(printf 'srs-domain = "%s"\ndomains = %s\nsocketmap = "inet:127.0.0.1:10003"' "$SRS_DOMAIN" "$list")
  if [[ $(grep -E '^(srs-domain|domains|socketmap)[[:space:]]*=' "$conf" | sort) != "$(sort <<<"$want")" ]]; then
    keep "$conf"
    set_conf srs-domain "\"$SRS_DOMAIN\""
    set_conf domains "$list"
    set_conf socketmap '"inet:127.0.0.1:10003"'
    ok "configured $conf"
  fi
  fwd=socketmap:inet:127.0.0.1:10003:forward
  rev=socketmap:inet:127.0.0.1:10003:reverse
elif [[ -f /etc/default/postsrsd ]]; then
  # postsrsd 1: separate forward and reverse TCP tables on loopback.
  conf=/etc/default/postsrsd
  excl=$(IFS=,; echo "${domains[*]:1}")
  set_def() {  # <key> <value>
    if grep -Eq "^#?[[:space:]]*$1=" "$conf"; then
      sed -i -E "0,/^#?[[:space:]]*$1=.*/s||$1=$2|" "$conf"
    else
      printf '%s=%s\n' "$1" "$2" >> "$conf"
    fi
  }
  if ! grep -qx "SRS_DOMAIN=$SRS_DOMAIN" "$conf" || ! grep -qx "SRS_EXCLUDE_DOMAINS=$excl" "$conf" \
     || ! grep -qx "SRS_LISTEN_ADDR=127.0.0.1" "$conf"; then
    keep "$conf"
    set_def SRS_DOMAIN "$SRS_DOMAIN"
    set_def SRS_EXCLUDE_DOMAINS "$excl"
    set_def SRS_LISTEN_ADDR 127.0.0.1
    ok "configured $conf"
  fi
  # shellcheck disable=SC1090
  fport=$(. "$conf"; echo "${SRS_FORWARD_PORT:-10001}")
  rport=$(. "$conf"; echo "${SRS_REVERSE_PORT:-10002}")
  fwd=tcp:127.0.0.1:$fport
  rev=tcp:127.0.0.1:$rport
else
  die "postsrsd installed, but neither /etc/postsrsd.conf nor /etc/default/postsrsd exists"
fi
systemctl enable -q postsrsd
systemctl restart postsrsd
sleep 1

# Prove the round trip before Postfix depends on it.
srs=$(postmap -q probe@example.org "$fwd" || true)
[[ $srs == SRS0[=+-]*@$SRS_DOMAIN ]] || die "forward lookup gave '$srs', want SRS0...@$SRS_DOMAIN"
back=$(postmap -q "$srs" "$rev" || true)
[[ $back == probe@example.org ]] || die "reverse lookup of $srs gave '$back'"
own=$(postmap -q "probe@${domains[-1]}" "$fwd" || true)
[[ -z $own || $own == "probe@${domains[-1]}" ]] || die "own domain ${domains[-1]} was rewritten to '$own'"
ok "probe@example.org <-> $srs; ${domains[-1]} left alone"

echo "== postfix"
# Envelope only: the From header the recipient sees, and DKIM signs, is left
# alone. Reverse mapping also covers the headers of bounces.
for p in sender_canonical_maps recipient_canonical_maps; do
  cur=$(postconf -h "$p")
  [[ -z $cur || $cur == "$fwd" || $cur == "$rev" ]] || die "$p is already '$cur' - merge by hand"
done
if [[ $(postconf -h sender_canonical_maps) != "$fwd" || $(postconf -h recipient_canonical_maps) != "$rev" \
      || $(postconf -h sender_canonical_classes) != envelope_sender \
      || $(postconf -h recipient_canonical_classes) != "envelope_recipient, header_recipient" ]]; then
  keep /etc/postfix/main.cf
  postconf -e "sender_canonical_maps = $fwd" \
              "sender_canonical_classes = envelope_sender" \
              "recipient_canonical_maps = $rev" \
              "recipient_canonical_classes = envelope_recipient, header_recipient"
  postfix check
  postfix reload
  ok "main.cf set, postfix reloaded"
else
  ok "main.cf is current"
fi

echo
echo "OK - forwarded mail now leaves as SRS0=...@$SRS_DOMAIN; check a message's Return-Path and spf=pass at the far end"
