#!/usr/bin/env bash
# Turn sally's automatic power-off on or off. Separate from deploy.sh on purpose:
# switched on before the BIOS power-on schedule exists, sally would turn itself
# off and stay off.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
HOST=192.168.8.22

case ${1:-} in
  on)  $SSH "root@$HOST" 'systemctl enable --now sally-power-off-when-done.timer' ;;
  off) $SSH "root@$HOST" 'systemctl disable --now sally-power-off-when-done.timer' ;;
  *)   echo "usage: $0 on|off"; exit 1 ;;
esac
$SSH "root@$HOST" 'systemctl is-enabled sally-power-off-when-done.timer || true'
