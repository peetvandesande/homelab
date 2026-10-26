#!/usr/bin/env bash
# Read the responder's reports from lexie.
#
#   scripts/reports.sh [N]        list the last N (default 10), newest first
#   scripts/reports.sh <file>     print one; "latest" for the newest
set -euo pipefail
R="ssh -o BatchMode=yes root@192.168.8.24"
D=/var/lib/responder/reports
case "${1:-10}" in
  *[!0-9]*)
    f=$1
    [[ $f == latest ]] && f=$($R "ls -t $D | head -1")
    [[ $f =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "bad name"; exit 1; }
    $R "cat '$D/$f'" ;;
  *) $R "ls -t $D | head -n ${1:-10}" ;;
esac
