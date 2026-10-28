#!/usr/bin/env bash
# Hand ruby's public :22 to Forgejo, and take ruby's own sshd off the
# internet. From ruby's clone, in an SSH session that came in over the VPN:
#
#   cd ~/homelab && git pull && sudo forgejo/scripts/install-ruby-ssh.sh
#
# then, from a NEW session over the VPN, within ten minutes:
#
#   sudo ~/homelab/forgejo/scripts/install-ruby-ssh.sh --confirm
#
# Without the confirm a timer puts sshd back on every address and removes the
# stream proxy, so a mistake here cannot lock you out for longer than that.
# `--rollback` does the same by hand. Safe to re-run. If everything else
# fails, OVH's KVM console still reaches the machine.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
SELF=$(realpath "$0")
REPO=$(cd "$(dirname "$SELF")/../.." && pwd)
SVC=$REPO/wireguard/ruby/services/etc
STREAM_SRC=$REPO/forgejo/ruby/etc/nginx/stream.d/git.peetvandesande.com-ssh.conf
STREAM=/etc/nginx/stream.d/git.peetvandesande.com-ssh.conf
SSHD=/etc/ssh/sshd_config.d/10-vpn-only.conf
UNIT_SVC=/etc/systemd/system/ssh.service.d/vpn-only.conf
UNIT_SOCK=/etc/systemd/system/ssh.socket.d/vpn-only.conf
TIMER=ruby-ssh-rollback
PRIVATE=(192.168.204.254 192.168.254.254 fd33:5692:1834:204::254 fd33:5692:1834:254::254)
PUBLIC=(145.239.73.18 2001:41d0:305:2100::1:3a0e)

ip -4 addr show dev dummy0 2>/dev/null | grep -q "inet 192.168.254.254/" || {
  echo "not ruby: no 192.168.254.254 on dummy0"; exit 1; }

restart_sshd() {
  systemctl daemon-reload
  if systemctl is-active --quiet ssh.socket; then
    systemctl restart ssh.socket
  else
    sshd -t
    systemctl restart ssh.service
  fi
}

case ${1:-} in
  --confirm)
    systemctl stop "$TIMER.timer" 2>/dev/null && echo "rollback cancelled - done" \
      || echo "no rollback pending"
    exit 0 ;;
  --rollback)
    echo "== rolling back"
    rm -f "$STREAM"
    nginx -t 2>/dev/null && systemctl reload nginx
    rm -f "$SSHD" "$UNIT_SVC" "$UNIT_SOCK"
    restart_sshd
    ss -Hltn 'sport = :22'
    exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--confirm|--rollback]"; exit 1 ;;
esac

echo "== preflight"
# The session running this must already be on a VPN address, or the switch
# would cut off the only way back in.
mine=$(ss -Htn state established '( sport = :22 )' | awk '{print $3}' | tr -d '[]')
vpn=0
for a in "${PRIVATE[@]}"; do grep -qF "$a:22" <<<"$mine" && vpn=1; done
[[ $vpn -eq 1 ]] || { echo "!! no SSH session to a VPN address of ruby - connect to 192.168.254.254 over the VPN and run this there"; exit 1; }
echo "   an SSH session over the VPN is open"

nginx -V 2>&1 | grep -q -- '--with-stream' || {
  echo "!! this nginx has no stream module - apt install libnginx-mod-stream"; exit 1; }
if ! grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/stream\.d/\*\.conf' /etc/nginx/nginx.conf; then
  grep -qE '^[[:space:]]*stream[[:space:]]*\{' /etc/nginx/nginx.conf && {
    echo "!! nginx.conf has its own stream block - add 'include /etc/nginx/stream.d/*.conf;' inside it"; exit 1; }
fi
origin=$(dig +short +time=3 +tries=1 @127.0.0.1 forgejo.home A | tail -1)
[[ -n $origin ]] || { echo "!! forgejo.home does not resolve via 127.0.0.1"; exit 1; }
want=$(ssh-keyscan -T 5 -t ed25519 "$origin" 2>/dev/null | awk '{print $3}')
[[ -n $want ]] || { echo "!! forgejo ($origin) does not answer on :22 over wg1"; exit 1; }
echo "   forgejo ($origin) answers on :22"

echo "== ruby's sshd onto the VPN addresses"
changed=0
for pair in "$SVC/ssh/sshd_config.d/10-vpn-only.conf:$SSHD" \
            "$SVC/systemd/system/ssh.service.d/vpn-only.conf:$UNIT_SVC" \
            "$SVC/systemd/system/ssh.socket.d/vpn-only.conf:$UNIT_SOCK"; do
  src=${pair%%:*} dst=${pair#*:}
  cmp -s "$src" "$dst" && continue
  install -d "$(dirname "$dst")"
  install -m 0644 "$src" "$dst"
  changed=1
done
if [[ $changed -eq 1 ]]; then
  # Armed before the restart, so even a restart that strands us undoes itself.
  systemctl stop "$TIMER.timer" 2>/dev/null || true
  systemctl reset-failed "$TIMER.service" 2>/dev/null || true
  systemd-run --quiet --unit="$TIMER" --on-active=10min "$SELF" --rollback
  echo "   rollback armed for 10 minutes"
  restart_sshd
fi
for _ in {1..5}; do
  listen=$(ss -Hltn 'sport = :22' | awk '{print $4}' | tr -d '[]')
  grep -qE '^(0\.0\.0\.0|::|\*):22$' <<<"$listen" || break
  sleep 1
done
fail=0
for a in "${PRIVATE[@]}"; do
  grep -qF "$a:22" <<<"$listen" && echo "   sshd on $a" || { echo "!! sshd is not on $a"; fail=1; }
done
grep -qE '^(0\.0\.0\.0|::|\*):22$' <<<"$listen" && { echo "!! something still listens on :22 on every address"; fail=1; }
[[ $fail -eq 0 ]] || { echo "FAIL - rolling back now"; "$SELF" --rollback; exit 1; }

echo "== nginx stream proxy on the public :22"
install -d /etc/nginx/stream.d
grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/stream\.d/\*\.conf' /etc/nginx/nginx.conf \
  || printf '\n# Managed by homelab forgejo/scripts/install-ruby-ssh.sh\nstream {\n    include /etc/nginx/stream.d/*.conf;\n}\n' >> /etc/nginx/nginx.conf
install -m 0644 "$STREAM_SRC" "$STREAM"
nginx -t || { echo "FAIL - rolling back now"; "$SELF" --rollback; exit 1; }
systemctl reload nginx

echo "== verify"
for a in "${PUBLIC[@]}"; do
  for _ in {1..10}; do
    got=$(ssh-keyscan -T 5 -t ed25519 "$a" 2>/dev/null | awk '{print $3}')
    [[ -n $got ]] && break
    sleep 1
  done
  [[ $got == "$want" ]] && echo "   $a:22 is forgejo (host key matches)" \
    || { echo "!! $a:22 answers ${got:+with another host key}${got:-nothing}"; fail=1; }
done
[[ $fail -eq 0 ]] || { echo "FAIL - rollback still armed"; exit 1; }
if systemctl is-active --quiet "$TIMER.timer"; then
  echo
  echo "Now open a NEW session over the VPN (ssh 192.168.254.254) and run:"
  echo "  sudo $SELF --confirm"
  echo "within 10 minutes, or this is undone."
fi
echo "OK"
