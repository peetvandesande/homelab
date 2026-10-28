#!/usr/bin/env bash
# Forgejo (192.168.8.62): HTTPS on :443 off the lab CA, git over SSH on :22.
#
# Run AFTER scripts/bootstrap.sh and ca/scripts/enrol.sh 192.168.8.62 forgejo
# git.peetvandesande.com - Forgejo serves host.crt itself and will not start
# without it.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.62

require_enrolled "$HOST"
push "$HOST" root
$SSH "root@$HOST" '
  set -e
  usermod -aG tlscert git
  chown root:git /etc/forgejo/app.ini && chmod 0640 /etc/forgejo/app.ini
  chmod +x /etc/homelab-tls/post-renew.d/20-forgejo
  # Logs go to the journal (app.ini [log]), but doctor insists the directory
  # exists; the others Forgejo would create lazily, and doctor fails without.
  install -d -o git -g git -m 0750 /var/lib/forgejo/log /var/lib/forgejo/data \
    /var/lib/forgejo/repositories

  # The secrets app.ini points at. Generated once, on the host, and never
  # again: a new SECRET_KEY cannot decrypt what the old one encrypted.
  install -d -o root -g git -m 0750 /etc/forgejo/secrets
  for s in secret_key internal_token jwt_secret lfs_jwt_secret; do
    f=/etc/forgejo/secrets/$s
    [ -s "$f" ] && continue
    case $s in
      secret_key)     kind=SECRET_KEY ;;
      internal_token) kind=INTERNAL_TOKEN ;;
      *)              kind=JWT_SECRET ;;
    esac
    umask 027; /usr/local/bin/forgejo generate secret $kind > "$f"
    chown root:git "$f"; chmod 0640 "$f"
    echo "   generated $s"
  done

  # Debian 13 starts sshd through ssh.socket, which holds :22. A reload makes
  # sshd re-exec and try to bind :22 itself, which the socket already has, so
  # it dies - and the next connection quietly starts it again through the
  # socket. A restart is what actually picks up a changed config.
  install -d -m 0755 /run/sshd
  sshd -t
  systemctl restart ssh.service
  systemctl daemon-reload
  systemctl enable forgejo >/dev/null
'
restart_assert "$HOST" forgejo
# The schema is created on first start; doctor finds anything the config
# promises that the host does not provide.
$SSH "root@$HOST" 'runuser -u git -- /usr/local/bin/forgejo doctor check --config /etc/forgejo/app.ini 2>&1 | tail -5'
echo "   forgejo restarted"
