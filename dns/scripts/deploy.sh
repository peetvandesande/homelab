#!/usr/bin/env bash
# Push configuration to themis/delphi/pythia and bring the services up.
# Run from anywhere; operates on the repo it lives in. Idempotent.
#
# Files are copied one at a time and written atomically as root:root. An
# earlier version streamed a tarball into / - don't go back to that: tar
# carries the workstation's uid/gid and mode on the archive's own top-level
# entry, which silently rewrote / to 0700 owned by uid 501.
set -euo pipefail

cd "$(dirname "$0")/.."
[[ -f secrets.env ]] || { echo "secrets.env missing - see README.md"; exit 1; }
# shellcheck disable=SC1091
source secrets.env

THEMIS=192.168.1.50
DELPHI=192.168.1.51
PYTHIA=192.168.1.52

# %C is a short hash; macOS temp dirs blow past the 104-char sockaddr limit.
CTL="/tmp/.dnsdeploy-%C"
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath=$CTL -o ControlPersist=60s"

subst() {
  sed -e "s|@@DNSDIST_CONSOLE_KEY@@|${DNSDIST_CONSOLE_KEY}|g" \
      -e "s|@@DNSDIST_API_KEY@@|${DNSDIST_API_KEY}|g" \
      -e "s|@@RECURSOR_API_KEY@@|${RECURSOR_API_KEY}|g" \
      -e "s|@@AUTH_API_KEY@@|${AUTH_API_KEY}|g" \
      -e "s|@@DNSDIST_API_KEY_HASHED@@|${DNSDIST_API_KEY_HASHED:-}|g" "$1"
}

# Restart, then assert the service actually settled. A bare `systemctl restart`
# can report failure when the outgoing pdns still holds its control socket;
# Restart=on-failure brings it straight back, so what matters is the end state.
restart_assert() { # restart_assert <host> <unit>
  $SSH "root@$1" "
    systemctl restart '$2' || true
    for _ in \$(seq 1 30); do systemctl is-active --quiet '$2' && exit 0; sleep 1; done
    echo '$2 did not come up'; systemctl status '$2' --no-pager -l | tail -20; exit 1
  "
}

# Bring up the TLS front for a host: our vhost is a default_server and so is
# the packaged one, and two of them is a fatal config error rather than a
# warning.
enable_nginx() { # enable_nginx <host>
  $SSH "root@$1" '
    set -e
    getent group tlscert >/dev/null || groupadd --system tlscert
    chmod +x /etc/homelab-tls/post-renew.d/* 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/metrics.conf /etc/nginx/sites-enabled/metrics.conf
    nginx -t
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx
  '
}

push() { # push <host> <srcdir>
  local host=$1 src=$2 rel mode
  echo "== pushing $src -> $host"
  while IFS= read -r rel; do
    rel=${rel#./}
    mode=0644
    [[ -x "$src/$rel" ]] && mode=0755
    subst "$src/$rel" | $SSH "root@$host" \
      "mkdir -p '/$(dirname "$rel")' && cat > '/$rel.deploytmp' \
       && chown root:root '/$rel.deploytmp' && chmod $mode '/$rel.deploytmp' \
       && mv -f '/$rel.deploytmp' '/$rel'"
    echo "   $rel ($mode)"
  done < <(cd "$src" && find . -type f | sort)
}

# ------------------------------------------------------------ TLS front -----
# None of the three PowerDNS components can serve TLS on its own webserver, so
# each gets an nginx in front of a loopback-bound backend. Hosts must already
# be enrolled with the CA - ca/scripts/enrol.sh --all.
for host in "$THEMIS" "$DELPHI" "$PYTHIA"; do
  $SSH "root@$host" '
    set -e
    test -s /etc/homelab-tls/host.crt || { echo "not enrolled - run ca/scripts/enrol.sh"; exit 1; }
    if ! command -v nginx >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq && apt-get install -y -qq nginx >/dev/null
    fi
  '
done

# ---------------------------------------------------------------- pythia ----
# Authoritative first: Delphi forwards to it, so it should be answering before
# the recursor starts caching failures for the internal zone.
push "$PYTHIA" pythia
$SSH root@$PYTHIA '
  set -e
  install -d -o pdns -g pdns -m 0755 /var/lib/powerdns/zones
  chown pdns:pdns /var/lib/powerdns/zones/*.zone
  chown root:pdns /etc/powerdns/pdns.conf && chmod 0640 /etc/powerdns/pdns.conf
  systemctl daemon-reload
  pdns_server --config=check >/dev/null
  systemctl reset-failed pdns 2>/dev/null || true
  systemctl enable --now pdns >/dev/null
'
restart_assert "$PYTHIA" pdns
enable_nginx "$PYTHIA"
echo "   pythia ok"

# ---------------------------------------------------------------- delphi ----
push "$DELPHI" delphi
$SSH root@$DELPHI '
  set -e
  install -d -o pdns -g pdns -m 0755 /var/lib/powerdns/rpz
  # A leftover old-style recursor.conf would be picked up ahead of the YAML.
  rm -f /etc/powerdns/recursor.conf
  chown root:pdns /etc/powerdns/recursor.yml && chmod 0640 /etc/powerdns/recursor.yml
  systemctl daemon-reload
  # Feeds must be on disk before the recursor starts: rpzFile() on a missing
  # file is a fatal startup error, not a warning.
  /usr/local/bin/rpz-update
  systemctl reset-failed pdns-recursor 2>/dev/null || true
  systemctl enable --now pdns-recursor >/dev/null
  systemctl enable --now rpz-update.timer >/dev/null
'
restart_assert "$DELPHI" pdns-recursor
enable_nginx "$DELPHI"
echo "   delphi ok"

# ---------------------------------------------------------------- themis ----
# dnsdist wants a scrypt hash, not the plaintext key. Mint it once and keep it
# in secrets.env - hashPassword() salts randomly, so recomputing every run
# would rewrite the config and bounce the service on every deploy.
if [[ -z "${DNSDIST_API_KEY_HASHED:-}" ]]; then
  echo "== minting dnsdist API key hash"
  DNSDIST_API_KEY_HASHED=$($SSH root@$THEMIS \
    "printf 'print(hashPassword(\"%s\"))\n' '$DNSDIST_API_KEY' > /tmp/h.conf \
     && dnsdist --check-config --config /tmp/h.conf 2>/dev/null | head -1; rm -f /tmp/h.conf")
  [[ $DNSDIST_API_KEY_HASHED == \$scrypt\$* ]] || { echo "hashPassword failed"; exit 1; }
  echo "DNSDIST_API_KEY_HASHED='${DNSDIST_API_KEY_HASHED}'" >> secrets.env
fi

push "$THEMIS" themis
$SSH root@$THEMIS '
  set -e
  # DoT/DoH: dnsdist reads the key itself and, unlike nginx, never runs as
  # root - User=_dnsdist in the unit. Group membership is how it gets in.
  getent group tlscert >/dev/null || groupadd --system tlscert
  usermod -aG tlscert _dnsdist
  chown root:_dnsdist /etc/dnsdist/dnsdist.conf /etc/dnsdist/kids-devices.conf 2>/dev/null || true
  chmod 0640 /etc/dnsdist/dnsdist.conf /etc/dnsdist/kids-devices.conf
  systemctl daemon-reload
  dnsdist --check-config --config /etc/dnsdist/dnsdist.conf
  systemctl reset-failed dnsdist 2>/dev/null || true
  systemctl enable --now dnsdist >/dev/null
'
restart_assert "$THEMIS" dnsdist
enable_nginx "$THEMIS"
echo "   themis ok"

echo
echo "== deployed - now run scripts/verify.sh"
