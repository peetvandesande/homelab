#!/usr/bin/env bash
# Install the weekly estate report on ruby. From the clone, with sudo:
#   sudo ~/homelab/estate-report/install.sh <recipient>
# The recipient is needed on the first run only. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
ip -4 addr show dev dummy0 2>/dev/null | grep -q "inet 192.168.254.254/" || {
  echo "not ruby: no 192.168.254.254 on dummy0"; exit 1; }

install -m 0755 root/usr/local/bin/estate-report /usr/local/bin/estate-report
install -d /etc/estate-report
# Prometheus's certificate chains to the lab root.
install -m 0644 ../ca/rootca/certs/root.crt /etc/estate-report/lab-root.crt
if [[ ! -s /etc/default/estate-report ]]; then
  [[ $# -eq 1 ]] || { echo "usage: $0 <recipient>   (first install)"; exit 1; }
  sed "s|@@REPORT_TO@@|$1|" root/etc/default/estate-report > /etc/default/estate-report
fi
install -m 0644 root/etc/systemd/system/estate-report.{service,timer} /etc/systemd/system/

systemctl daemon-reload
systemctl enable --quiet --now estate-report.timer
systemctl list-timers --no-pager estate-report.timer | head -2

echo "== last week's report, printed rather than sent"
set -a; . /etc/default/estate-report; set +a
/usr/local/bin/estate-report --stdout
echo
echo "Send it now with: sudo systemctl start estate-report.service"
