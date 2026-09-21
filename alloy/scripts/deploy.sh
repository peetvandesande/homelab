#!/usr/bin/env bash
# Ship every host's journal to Loki with Grafana Alloy, across the whole fleet.
#
# One directory for eleven hosts, like node-exporter/: this is one service
# replicated, not a per-container concern. Idempotent - installs the pinned
# package where it is missing, pushes the same four files everywhere, and
# proves each host is both serving TLS on :12345 and actually landing lines in
# Loki before moving on.
#
#   scripts/deploy.sh            the whole fleet
#   scripts/deploy.sh <ip>...    just those hosts (a new container)
#
# Prometheus scrapes :12345, so prometheus/scripts/deploy.sh after this, once,
# if the fleet changed. Unlike node-exporter there is no window where anything
# breaks: until Prometheus knows about the job the metrics are simply unread.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh

LOKI=192.168.1.56
CA_ROOT=../ca/rootca/certs/root.crt
CURL="curl -sS --max-time 10 --cacert $CA_ROOT"

# Pinned and held, like Loki itself: Alloy's config language moves between
# minors. Bump deliberately, together with root/etc/alloy/config.alloy, and
# let `alloy validate` on the deploy prove the pair.
ALLOY_VER="1.19.2"

FLEET=(
  192.168.1.21 192.168.1.50 192.168.1.51 192.168.1.52 192.168.1.53
  192.168.1.54 192.168.1.55 192.168.1.56 192.168.1.60 192.168.1.61
  192.168.1.27
)
[[ $# -gt 0 ]] && FLEET=("$@")

# Loki must be reachable before touching a single host, or eleven Alloys come up
# and buffer against nothing.
$CURL -o /dev/null -f "https://$LOKI:3100/ready" \
  || { echo "loki at $LOKI is not ready - deploy loki/ first"; exit 1; }

for ip in "${FLEET[@]}"; do
  echo "-------------------------------------------------- $ip"
  require_enrolled "$ip"

  $SSH "root@$ip" "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    # Same repo Grafana (.54) and Loki (.56) install from; the other eight
    # hosts, lenora included, gain it here.
    if [ ! -s /etc/apt/keyrings/grafana.gpg ]; then
      apt-get install -y -qq curl ca-certificates gnupg >/dev/null
      install -d -m 0755 /etc/apt/keyrings
      curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
      echo 'deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main' \
        > /etc/apt/sources.list.d/grafana.list
      apt-get update -qq
    fi
    if dpkg -s alloy 2>/dev/null | grep -q '^Version: ${ALLOY_VER}-'; then
      echo '   alloy ${ALLOY_VER} already installed'
    else
      apt-get update -qq
      apt-get install -y -qq --allow-downgrades alloy=${ALLOY_VER}-1 >/dev/null
      echo '   alloy ${ALLOY_VER} installed'
    fi
    apt-mark hold alloy >/dev/null
  "

  push "$ip" root

  $SSH "root@$ip" '
    set -e
    # Journal read needs both groups; the key needs tlscert. The drop-in names
    # them too - see root/etc/systemd/system/alloy.service.d/homelab.conf.
    usermod -aG systemd-journal,adm,tlscert alloy
    chmod +x /etc/homelab-tls/post-renew.d/15-alloy
    chown root:alloy /etc/alloy/*.alloy && chmod 0640 /etc/alloy/*.alloy
    install -d -o alloy -g alloy -m 0750 /var/lib/alloy /var/lib/alloy/data
    # Parses the whole directory without starting anything - the fleet file
    # plus whatever this host added (loki has esxi.alloy). Runs as root, so
    # it proves the syntax, not that alloy can read the key - the restart
    # proves that.
    alloy validate /etc/alloy >/dev/null
    systemctl daemon-reload
    systemctl enable alloy >/dev/null
  '
  restart_assert "$ip" alloy

  # Prove it is serving TLS off our root, not merely running. is-active
  # comes true before the listener does, so give it a few seconds.
  ok=0
  for _ in $(seq 1 10); do
    $CURL -o /dev/null -f "https://$ip:12345/-/ready" 2>/dev/null && { ok=1; break; }
    sleep 3
  done
  if [[ $ok -eq 1 ]]; then
    echo "   $ip:12345 ready, serving TLS, verifies against the G2 root"
  else
    echo "   $ip:12345 FAILED TLS check"; $SSH "root@$ip" 'journalctl -u alloy --no-pager -n 20'; exit 1
  fi

  # Prove lines from this host are landing in Loki. A fresh Alloy backfills up
  # to a week of journal, so the first push is seconds away; give it a minute.
  name=$($SSH "root@$ip" hostname)
  ok=0
  for _ in $(seq 1 12); do
    n=$($CURL -G "https://$LOKI:3100/loki/api/v1/query" \
          --data-urlencode "query=count_over_time({host=\"$name\"}[10m])" 2>/dev/null \
        | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(sum(int(v["value"][1]) for v in r))' 2>/dev/null || echo 0)
    [[ ${n:-0} -gt 0 ]] && { ok=1; break; }
    sleep 5
  done
  if [[ $ok -eq 1 ]]; then
    echo "   loki has lines for host=\"$name\""
  else
    echo "   NO lines for host=\"$name\" in loki after 60s"
    $SSH "root@$ip" 'journalctl -u alloy --no-pager -n 20'
    exit 1
  fi
done

echo
echo "== every host in the fleet ships its journal to loki"
echo "   if the fleet changed: add the alloy target to prometheus/root/etc/prometheus/prometheus.yml,"
echo "   then prometheus/scripts/deploy.sh"
