#!/usr/bin/env bash
# Smoke test the DNS stack from a workstation on the LAN.
# Every query goes to Themis, because that is the only address clients use.
#
# Exit status is the number of failed checks.

# Relative paths below (scripts/, ../ca/) are resolved from dns/, not from
# wherever this was invoked.
cd "$(dirname "$0")/.."
THEMIS=192.168.8.50
DIG="dig +time=3 +tries=1 @$THEMIS"
# Our own root. Defined up here because the sync check needs it too, not just
# the TLS section further down.
CA=../ca/rootca/certs/root.crt
ROUTER=${ROUTER:-192.168.8.1}
RSSH="ssh -o BatchMode=yes -o ConnectTimeout=5 root@$ROUTER"
fail=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n        got: %s\n' "$1" "$2"; fail=$((fail+1)); }

check_eq() { # check_eq <label> <expected> <actual>
  [[ "$3" == "$2" ]] && pass "$1" || bad "$1 (expected '$2')" "$3"
}
status() { $DIG "$@" 2>/dev/null | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -1; }

echo "== internal zones (Pythia, via Delphi's forward-zone)"
check_eq "grafana.home resolves"        "192.168.8.54" "$($DIG grafana.home A +short)"
check_eq "lenora.home resolves"         "192.168.8.21" "$($DIG lenora.home A +short)"
check_eq "dns.home is a CNAME to themis" "themis.home." "$($DIG dns.home CNAME +short)"
check_eq "reverse of .54"               "grafana.home." "$($DIG -x 192.168.8.54 +short)"
check_eq "internal name never leaks"    "NXDOMAIN" "$(status nosuchhost.home A)"

echo "== split-horizon override of a public name"
check_eq "ca.peetvandesande.com answers with pistis, not the VPS" \
  "192.168.8.55" "$($DIG ca.peetvandesande.com A +short)"
check_eq "mail.peetvandesande.com answers with ruby's tunnel address" \
  "192.168.254.254" "$($DIG mail.peetvandesande.com A +short)"
check_eq "mail.peetvandesande.com answers with ruby's tunnel ULA" \
  "fd33:5692:1834:254::254" "$($DIG mail.peetvandesande.com AAAA +short)"
check_eq "ruby.peetvandesande.com answers with ruby's tunnel address" \
  "192.168.254.254" "$($DIG ruby.peetvandesande.com A +short)"
check_eq "ruby.peetvandesande.com answers with ruby's tunnel ULA" \
  "fd33:5692:1834:254::254" "$($DIG ruby.peetvandesande.com AAAA +short)"
# Scoping: the NTA must cover the one name and nothing more, so the parent
# domain has to keep validating. A missing 'ad' here means the NTA is too wide
# and peetvandesande.com is no longer DNSSEC-protected for the whole LAN.
if $DIG peetvandesande.com A +dnssec 2>/dev/null | grep -q 'flags:.* ad'; then
  pass "parent domain peetvandesande.com still validates (NTA correctly scoped)"
else
  bad "parent domain peetvandesande.com still validates (NTA correctly scoped)" "no ad flag"
fi

echo "== recursion"
[[ -n "$($DIG example.com A +short)" ]] && pass "example.com resolves" || bad "example.com resolves" "empty"
check_eq "DNSSEC bogus is rejected" "SERVFAIL" "$(status dnssec-failed.org A)"
if $DIG cloudflare.com A +dnssec 2>/dev/null | grep -q 'flags:.* ad'; then
  pass "DNSSEC AD flag set on a signed zone"
else
  bad "DNSSEC AD flag set on a signed zone" "no ad flag"
fi

echo "== filtering: policy sets"
# Every hagezi list ships a canary domain named after the list file, so each
# feed can be tested exactly rather than by picking a name out of it and hoping
# it stays listed. Derived from the URLs in rpz-feeds.conf, so adding a feed
# there is enough - nothing here needs editing.
canary() { # canary <feed-name>
  awk -v f="$1" '$1==f { n=$3; sub(/.*\//,"",n); sub(/\.txt$/,"",n); gsub(/\./,"-",n);
                         print "h4g3z1-" n ".web.app"; exit }' delphi/etc/powerdns/rpz-feeds.conf
}
check_feed() { # check_feed <feed> <NXDOMAIN|NOERROR> <note>
  local c; c=$(canary "$1")
  [[ -n "$c" ]] || { bad "$1 feed canary" "no such feed in rpz-feeds.conf"; return; }
  check_eq "$1 $3" "$2" "$(status "$c" A)"
}

echo "   default set - applies to every client"
check_feed malware "NXDOMAIN" "blocks its canary"
check_feed ads     "NXDOMAIN" "blocks its canary"
check_feed doh     "NXDOMAIN" "blocks its canary"

echo "   kids set - must NOT apply to this workstation"
echo "   (if this host is in client-policies.conf these will read NXDOMAIN)"
for f in adult gambling nosafesearch social dohbypass; do
  check_feed "$f" "NOERROR" "not applied here"
done

echo "   iot set - must NOT apply to this workstation"
check_feed native_samsung "NOERROR" "not applied here"

echo "== VPN policy domains: resolved by the router, not Delphi"
# The router routes by destination IP and fills the ipset from the answers its
# own dnsmasq returns. So the real assertion is not that the name resolves -
# it is that what Themis handed back is in the set the routing rule matches on.
# The set name comes from the router, which owns the policy - there is no
# committed copy to read since the sync took over.
vpn_set=$($RSSH 'awk -F/ "{print \$3}" /var/run/dnsmasq/via_domain | cut -d, -f1 | sort -u' 2>/dev/null | head -1)
vpn_ips=$($DIG bbc.co.uk A +short | grep -E '^[0-9.]+$')
if [[ -z "$vpn_ips" ]]; then
  bad "bbc.co.uk resolves through Themis" "empty"
elif [[ -z "$vpn_set" ]]; then
  bad "vpn-domains.conf names an ipset" "no set found - was it generated?"
else
  miss=0
  for ip in $vpn_ips; do
    # Since firmware 4.11 (fw4) the set is an nft set, named in via_domain as
    # <family>#<table-family>#<table>#<set>; the legacy form is a bare ipset.
    if [[ $vpn_set == *#* ]]; then
      IFS='#' read -r _ tf tbl set <<<"$vpn_set"
      $RSSH "nft get element $tf $tbl $set '{ $ip }'" >/dev/null 2>&1 || miss=$((miss+1))
    else
      $RSSH "ipset test $vpn_set $ip" >/dev/null 2>&1 || miss=$((miss+1))
    fi
  done
  if (( miss )); then
    bad "every address returned for bbc.co.uk is in $vpn_set" \
        "$miss of $(echo "$vpn_ips" | wc -w | tr -d ' ') missing - the shunt is not reaching the tunnel's dnsmasq"
  else
    pass "every address returned for bbc.co.uk is in $vpn_set (policy routing will fire)"
  fi
fi
# Shunted names bypass Delphi entirely, which is what keeps the ads feed from
# blocking a telemetry name the routing policy itself lists.
check_eq "bbc-reporting-api.app is not filtered" "NOERROR" "$(status bbc-reporting-api.app A)"

echo "== the hourly sync from the router"
# The router owns the policy and Themis pulls it hourly, so the check is no
# longer "does the committed copy match" - it is "did the sync run, succeed, and
# find anything". A sync that silently stops leaves a shunt that slowly goes
# stale, which is invisible from the outside.
M=$(curl -sS --max-time 8 --cacert "$CA" https://192.168.8.50:9100/metrics 2>/dev/null)
# Prometheus exposition renders large numbers as 1.79e+09, so convert rather
# than string-slicing a timestamp.
m() { printf '%s\n' "$M" | awk -v k="$1" '$1==k {printf "%d", $2; exit}'; }
check_eq "last sync succeeded" "1" "$(m vpn_domain_sync_success)"
last=$(m vpn_domain_sync_last_success_seconds)
if [[ -z "$last" ]]; then
  bad "a sync has succeeded in the last 2h" "no vpn_domain_sync_last_success_seconds metric"
else
  age=$(( $(date +%s) - last ))
  if (( age < 7200 )); then
    pass "a sync has succeeded in the last 2h (${age}s ago)"
  else
    bad "a sync has succeeded in the last 2h" "${age}s ago - is vpn-domain-sync.timer running?"
  fi
fi
doms=$(printf '%s\n' "$M" | awk -F' ' '/^vpn_domain_sync_domains\{/ {s+=$2} END {print s+0}')
if (( doms > 0 )); then
  pass "the shunt covers $doms domain(s)"
else
  bad "the shunt covers at least one domain" "0 - the tunnel will never be used"
fi

echo "== hygiene"
check_eq "ANY is refused" "REFUSED" "$(status example.com ANY)"
check_eq "Firefox DoH canary is NXDOMAIN for every client" "NXDOMAIN" "$(status use-application-dns.net A)"

echo "== encrypted transports (dnsdist)"
# Verified against our own root, and against the IP - every lab certificate
# carries an IP SAN, which is what a client pinning the address verifies.
if a=$(./scripts/dns-tls-query.py dot 192.168.8.50 853 grafana.home "$CA" 2>&1); then
  check_eq "DoT :853 resolves grafana.home" "192.168.8.54" "$a"
else
  bad "DoT :853 resolves grafana.home" "$a"
fi
# curl, not the helper: dnsdist's DoH frontend advertises ALPN h2 only. This
# also proves the whole chain end to end - resolve an internal name over DoH,
# connect to what it returns, and validate that host's certificate for it.
if curl -sS --max-time 10 --cacert "$CA" --doh-url https://192.168.8.50/dns-query \
     -o /dev/null https://grafana.home:3000/api/health 2>/dev/null; then
  pass "DoH :443 resolves grafana.home, and its certificate validates for that name"
else
  bad "DoH :443 resolves grafana.home" "DoH lookup or the follow-on TLS connection failed"
fi

echo "== metrics endpoints (TLS, terminated by nginx)"
for t in "themis dnsdist 192.168.8.50:8083" "delphi recursor 192.168.8.51:8082" "pythia auth 192.168.8.52:8081"; do
  set -- $t
  # nginx allows only Prometheus (.53), so a workstation gets 403 - which still
  # proves TLS terminated and the chain verified. 200 means this host is .53.
  code=$(curl -sS --max-time 8 --cacert "$CA" -o /dev/null -w '%{http_code}' "https://$3/metrics" 2>/dev/null || echo 000)
  case "$code" in
    200|403) pass "$1 $2 serves TLS on $3 (http=$code)" ;;
    000)     bad "$1 $2 serves TLS on $3" "no TLS handshake - is nginx up and the cert valid?" ;;
    *)       bad "$1 $2 serves TLS on $3" "http=$code" ;;
  esac
  # The backend must not be reachable off-box any more; that is the whole point
  # of moving it to loopback.
  if nc -z -G 2 "${3%%:*}" "$(case ${3##*:} in 8083) echo 8383;; 8082) echo 8282;; 8081) echo 8181;; esac)" 2>/dev/null; then
    bad "$1 $2 backend is loopback-only" "the plain-HTTP backend port is reachable from the LAN"
  else
    pass "$1 $2 backend is loopback-only"
  fi
done

echo
if (( fail )); then echo "$fail check(s) failed"; else echo "all checks passed"; fi
exit $fail
