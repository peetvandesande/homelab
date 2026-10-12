#!/usr/bin/env bash
# hermes (192.168.8.57): push the config, apply the mailcow.conf overrides,
# install the lab certificate and converge the mailcow stack.
#
# Run this AFTER bootstrap.sh and ca/scripts/enrol.sh 192.168.8.57 hermes -
# mailcow would otherwise serve its snake-oil certificate.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.57
MC=/opt/mailcow-dockerized

require_enrolled "$HOST"
$SSH "root@$HOST" "test -f $MC/mailcow.conf" \
  || { echo "$HOST has no mailcow.conf - run scripts/bootstrap.sh first"; exit 1; }

# What each file needs when it changes: the engine a restart, postfix and
# rspamd a container restart. Hash before and after the push, so an unchanged
# deploy bounces nothing.
sums() {
  $SSH "root@$HOST" "cd / && sha256sum etc/docker/daemon.json \
    ${MC#/}/data/conf/postfix/extra.cf \
    ${MC#/}/data/conf/rspamd/override.d/options.inc \
    ${MC#/}/data/conf/rspamd/override.d/homelab-local-addrs.map 2>/dev/null" || true
}
before=$(sums)
push "$HOST" root
after=$(sums)
changed() { ! diff <(grep "$1" <<<"$before") <(grep "$1" <<<"$after") >/dev/null; }

restart=()
changed postfix/ && restart+=(postfix-mailcow)
changed rspamd/  && restart+=(rspamd-mailcow)

if changed daemon.json; then
  echo "== daemon.json changed, restarting the engine (mailcow goes down briefly)"
  $SSH "root@$HOST" 'dockerd --validate --config-file /etc/docker/daemon.json'
  restart_assert "$HOST" docker
  restart=()   # every container just restarted anyway
fi

echo "== mailcow.conf overrides"
$SSH "root@$HOST" "
  set -e
  cd $MC
  grep -E '^[A-Z_]+=' /etc/homelab-mailcow/mailcow.conf.overrides | while IFS='=' read -r k v; do
    if grep -q \"^\$k=\" mailcow.conf; then
      sed -i \"s|^\$k=.*|\$k=\$v|\" mailcow.conf
    else
      echo \"\$k=\$v\" >> mailcow.conf
    fi
    echo \"   \$k=\$v\"
  done
"

echo "== certificate and stack"
$SSH "root@$HOST" "
  set -e
  chmod +x /etc/homelab-tls/post-renew.d/30-mailcow /usr/local/sbin/homelab-mailcow-textfile
  # Copies the certificate in, and restarts the TLS services if they are up.
  /etc/homelab-tls/post-renew.d/30-mailcow
  cd $MC
  # Recreates only containers whose environment changed, e.g. an override.
  docker compose up -d --remove-orphans --quiet-pull
  ${restart[*]:+docker compose restart ${restart[*]}}
  systemctl daemon-reload
  systemctl enable --now homelab-mailcow-textfile.timer >/dev/null
"
echo "   mailcow converged${restart[*]:+, restarted ${restart[*]}}"
