# Shared helpers for the per-container deploy scripts (grafana/, jellyfin/,
# navidrome/, prometheus/, node-exporter/). Sourced, not executed.
#
# Lives in ca/ because every one of those stacks depends on the CA: they exist
# in their current shape only because they serve TLS off it.
#
# Files are copied one at a time and written atomically as root:root. An
# earlier version of the DNS deploy streamed a tarball into / - don't go back
# to that: tar carries the workstation's uid/gid and mode on the archive's own
# top-level entry, which silently rewrote / to 0700 owned by uid 501.

# %C is a short hash; macOS temp dirs blow past the 104-char sockaddr limit.
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath=/tmp/.hldeploy-%C -o ControlPersist=60s"

push() { # push <host> <srcdir>
  local host=$1 src=$2 rel mode
  echo "== pushing $src -> $host"
  while IFS= read -r rel; do
    rel=${rel#./}
    mode=0644
    [[ -x "$src/$rel" ]] && mode=0755
    $SSH "root@$host" \
      "mkdir -p '/$(dirname "$rel")' && cat > '/$rel.deploytmp' \
       && chown root:root '/$rel.deploytmp' && chmod $mode '/$rel.deploytmp' \
       && mv -f '/$rel.deploytmp' '/$rel'" < "$src/$rel"
    echo "   $rel ($mode)"
  done < <(cd "$src" && find . -type f ! -name .gitkeep | sort)
}

# Restart, then assert the service actually settled. A bare `systemctl restart`
# can report failure while the outgoing process still holds its listener;
# Restart=on-failure brings it straight back, so what matters is the end state.
restart_assert() { # restart_assert <host> <unit>
  $SSH "root@$1" "
    systemctl restart '$2' || true
    for _ in \$(seq 1 30); do systemctl is-active --quiet '$2' && exit 0; sleep 1; done
    echo '$2 did not come up'; journalctl -u '$2' --no-pager -n 30; exit 1
  "
}

# Refuse to enable TLS on a host that has no certificate yet. Without this the
# service comes up broken and the failure surfaces as a scrape error somewhere
# else entirely.
require_enrolled() { # require_enrolled <host>
  $SSH "root@$1" 'test -s /etc/homelab-tls/host.crt && test -s /etc/homelab-tls/host.key' \
    || { echo "$1 is not enrolled - run ca/scripts/enrol.sh first"; exit 1; }
}
