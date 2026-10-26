#!/usr/bin/env bash
# Give the responder an unprivileged way into each enrolled host: a `responder`
# user in the journal and adm groups, with lexie's public key, accepted from
# lexie only. It can read logs and run systemctl status; it cannot write
# anything or become root.
#
#   scripts/hosts.sh             the whole fleet
#   scripts/hosts.sh <ip>...     just those hosts
set -euo pipefail
cd "$(dirname "$0")/.."
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
LEXIE=192.168.8.24

# Same source as fleet/scripts/deploy.sh - one list, not another copy.
mapfile -t HOSTS < <(sed -n '/^FLEET=(/,/^)/p' ../ca/scripts/enrol.sh \
  | sed -n 's/^[[:space:]]*"\([0-9.][0-9.]*\)[[:space:]]\([a-z0-9-]*\).*/\1 \2/p')
if (( $# )); then
  mapfile -t HOSTS < <(printf '%s\n' "${HOSTS[@]}" | awk -v w=" $* " 'index(w, " " $1 " ")')
fi
(( ${#HOSTS[@]} )) || { echo "no hosts"; exit 1; }

PUB=$($SSH "root@$LEXIE" 'cat /var/lib/responder/.ssh/id_ed25519.pub')
[[ $PUB == ssh-ed25519\ * ]] || { echo "no responder key on lexie - run deploy.sh first"; exit 1; }

rc=0
for entry in "${HOSTS[@]}"; do
  read -r ip name <<<"$entry"
  printf '  %-14s %-11s ' "$ip" "$name"
  # Lexie's own name resolves to loopback (root CLAUDE.md, Container defaults),
  # so when the responder checks lexie it arrives from 127.0.0.1.
  from=$LEXIE; [[ $ip == "$LEXIE" ]] && from="$LEXIE,127.0.0.1"
  $SSH "root@$ip" "
    set -e
    id responder >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --comment 'alert responder' responder
    usermod -aG systemd-journal,adm responder
    passwd -l responder >/dev/null
    # The account's real home, not an assumed one: on lexie it is the
    # responder service user, whose home is /var/lib/responder.
    h=\$(getent passwd responder | cut -d: -f6)
    install -d -o responder -g responder -m 0700 \$h/.ssh
    printf '%s\n' 'from=\"$from\" $PUB' > \$h/.ssh/authorized_keys
    chown responder:responder \$h/.ssh/authorized_keys && chmod 0600 \$h/.ssh/authorized_keys
  " && echo ok || { echo FAILED; rc=1; }
done

# The responder's ssh is non-interactive, so an unknown host key is a hard
# failure rather than a prompt – the first live report said exactly that. Seed
# known_hosts from the hosts themselves, by name and by address, so the keys are
# checked from then on instead of trusted on first use at 3 a.m.
names=$(printf '%s\n' "${HOSTS[@]}" | awk '{printf "%s.home %s ", $2, $1}')
$SSH "root@$LEXIE" "
  set -e
  f=/var/lib/responder/.ssh/known_hosts
  { cat \$f 2>/dev/null; ssh-keyscan -q -t ed25519 $names 2>/dev/null; } | sort -u > \$f.new
  install -o responder -g responder -m 0600 \$f.new \$f && rm -f \$f.new
  echo \"   known_hosts: \$(wc -l < \$f) entries\"
" || rc=1
exit $rc
