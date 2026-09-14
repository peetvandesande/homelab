# Shared assertions for the per-container verify scripts. Sourced, not run.
# Every one of them needs the same three questions answered: is it TLS, does it
# chain to our root, and is the certificate the CA actually issued.
CA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rootca/certs/root.crt"
fail=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n        got: %s\n' "$1" "$2"; fail=$((fail+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n        %s\n' "$1" "$2"; }

# Verifies the served chain against the G2 root, NOT the system store - so a
# pass here means our CA, not merely "some TLS".
https_ok() { # https_ok <label> <url> [expected-code]
  local code
  code=$(curl -sS --max-time 10 --cacert "$CA_ROOT" -o /dev/null -w '%{http_code}' "$2" 2>/dev/null || echo 000)
  if [[ "$code" == "${3:-200}" ]]; then pass "$1 ($code over TLS, verified against the G2 root)"
  else bad "$1" "http=$code (000 means the TLS handshake or chain failed)"; fi
}

# The leaf alone is not enough: a server that sends no intermediate verifies
# here only by luck of a cached chain. Assert the intermediate is on the wire.
chain_ok() { # chain_ok <label> <host:port>
  local out
  out=$(echo | openssl s_client -connect "$2" -CAfile "$CA_ROOT" 2>/dev/null)
  if grep -q "Verify return code: 0 (ok)" <<<"$out" \
     && grep -q "Intermediate CA G3" <<<"$out"; then
    pass "$1 sends leaf + G3 intermediate and verifies"
  else
    bad "$1 sends leaf + G3 intermediate and verifies" \
        "$(grep -m1 'Verify return code' <<<"$out" || echo 'no handshake')"
  fi
}

renewal_ok() { # renewal_ok <label> <host>
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$2" \
       'systemctl is-enabled --quiet homelab-tls-renew.timer' 2>/dev/null; then
    pass "$1 renewal timer enabled"
  else bad "$1 renewal timer enabled" "timer not enabled"; fi
}

# A TLS-only Go server answers plain HTTP with 400 "Client sent an HTTP request
# to an HTTPS server" rather than refusing the connection - so curl SUCCEEDS.
# Checking curl's exit status marks a correctly-configured server as broken;
# what matters is that it never serves a 200.
no_plain_http() { # no_plain_http <label> <url>
  local code
  code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$2" 2>/dev/null || echo 000)
  case "$code" in
    200) bad "$1" "plain HTTP returned 200 - TLS is not enforced" ;;
    400) pass "$1 (400: client sent an HTTP request to an HTTPS server)" ;;
    000) pass "$1 (connection refused)" ;;
    *)   pass "$1 (http=$code, not a 200)" ;;
  esac
}
