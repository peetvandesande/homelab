#!/usr/bin/env bash
# Move one compose stack from the old moby (192.168.1.25) to this one.
#
#   scripts/import-stack.sh [--stop] [--up] <stack> [src-host]
#
#   --stop   stop the stack on the source first. A named volume copied out
#            from under a running database is a corrupt database, so this is
#            what you want for anything that holds state. Without it the copy
#            is hot and the script says so.
#   --up     bring the stack up here once everything is across.
#
# Runs from the workstation and drives both hosts over SSH; nothing needs a
# key from one host to the other. Volumes are streamed through a throwaway
# container rather than read out of /var/lib/docker - the engine owns that
# tree, and on the receiving side it is the only way to land the data with the
# ownership the image expects.
#
# Refuses to overwrite: an existing stack directory or a non-empty volume here
# stops the run. Re-importing means removing those first, deliberately.
set -euo pipefail

STOP=0; UP=0
while [[ ${1:-} == --* ]]; do
  case "$1" in
    --stop) STOP=1 ;;
    --up)   UP=1 ;;
    *) echo "unknown flag: $1"; exit 1 ;;
  esac
  shift
done

STACK=${1:?usage: import-stack.sh [--stop] [--up] <stack> [src-host]}
SRC=${2:-192.168.1.25}
DST=192.168.1.27
DIR=/opt/stacks/$STACK

SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath=/tmp/.hlimport-%C -o ControlPersist=60s"

echo "== preflight"
for h in "$SRC" "$DST"; do
  $SSH "root@$h" 'command -v docker >/dev/null' \
    || { echo "no docker on $h (or no root SSH)"; exit 1; }
done
$SSH "root@$SRC" "test -d '$DIR'" \
  || { echo "$SRC has no $DIR - pass the stack name as it is on the source"; exit 1; }
$SSH "root@$DST" "test ! -e '$DIR'" \
  || { echo "$DST already has $DIR - remove it first if you mean to re-import"; exit 1; }
COMPOSE=$($SSH "root@$SRC" "ls '$DIR'/compose.y*ml '$DIR'/docker-compose.y*ml 2>/dev/null | head -1")
[[ -n "$COMPOSE" ]] || { echo "no compose file in $SRC:$DIR"; exit 1; }
echo "   $SRC:$COMPOSE"

# The project name compose uses by default is the directory name; every
# resource it created carries it as a label, which is how the volumes below
# are found without parsing YAML.
VOLUMES=$($SSH "root@$SRC" \
  "docker volume ls -q --filter label=com.docker.compose.project=$STACK" || true)
echo "   volumes: ${VOLUMES:-none}"

for v in $VOLUMES; do
  if $SSH "root@$DST" "docker volume inspect '$v' >/dev/null 2>&1"; then
    empty=$($SSH "root@$DST" "docker run --rm -v '$v':/v alpine sh -c 'ls -A /v | wc -l'")
    [[ "$empty" == "0" ]] \
      || { echo "$DST already has a non-empty volume $v - remove it first"; exit 1; }
  fi
done

if [[ $STOP -eq 1 ]]; then
  echo "== stopping $STACK on $SRC"
  $SSH "root@$SRC" "cd '$DIR' && docker compose stop"
elif [[ -n "$VOLUMES" ]]; then
  echo "   WARNING: copying volumes while the stack is running on $SRC."
  echo "            Anything with a database wants --stop instead."
fi

echo "== copying $DIR"
# -p keeps modes; the tree is config, not data, so this is a plain tar stream.
$SSH "root@$SRC" "tar -C /opt/stacks -cf - '$STACK'" \
  | $SSH "root@$DST" "mkdir -p /opt/stacks && tar -C /opt/stacks -xpf -"

for v in $VOLUMES; do
  echo "== copying volume $v"
  # -p on extract matters: uid/gid inside the volume is what the image looks
  # for, and it has nothing to do with the uid the tar runs as.
  $SSH "root@$SRC" "docker run --rm -v '$v':/v:ro alpine tar -C /v -cf - ." \
    | $SSH "root@$DST" "docker volume create '$v' >/dev/null && docker run --rm -i -v '$v':/v alpine tar -C /v -xpf -"
  src_n=$($SSH "root@$SRC" "docker run --rm -v '$v':/v:ro alpine sh -c 'find /v | wc -l'")
  dst_n=$($SSH "root@$DST" "docker run --rm -v '$v':/v alpine sh -c 'find /v | wc -l'")
  [[ "$src_n" == "$dst_n" ]] && echo "   $v: $dst_n entries, matches source" \
    || { echo "   $v: $dst_n entries here vs $src_n on source - NOT copied cleanly"; exit 1; }
done

if [[ $UP -eq 1 ]]; then
  echo "== starting $STACK on $DST"
  $SSH "root@$DST" "cd '$DIR' && docker compose up -d"
  $SSH "root@$DST" "cd '$DIR' && docker compose ps"
fi

echo
echo "== $STACK is on $DST"
echo "   published ports now answer on $DST, not $SRC - check anything on the"
echo "   LAN that still points at the old address."
echo "   logs: {host=\"moby\", container=\"...\"} in Grafana"
