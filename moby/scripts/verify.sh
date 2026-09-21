#!/usr/bin/env bash
# Checks the intent of moby/: a Docker host that can actually run containers,
# whose engine metrics are TLS off the lab CA, and whose containers' logs
# reach Loki. Read-only - it pulls and runs one throwaway container.
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.1.27
LENORA=192.168.1.21
PROM=192.168.1.53
LOKI=192.168.1.56
CURL="curl -sS --max-time 10 --cacert $CA_ROOT"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"

echo "== container settings"
# keyctl is the one Docker adds to the fleet default, and a features change
# only takes effect on a restart - so a config that says keyctl while the
# running container predates the change would still be broken. Both matter.
feat=$($SSH "root@$LENORA" "pct config 108 | sed -n 's/^features: //p'" 2>/dev/null)
[[ "$feat" == "nesting=1,keyctl=1" ]] \
  && pass "CT 108 features are nesting=1,keyctl=1" \
  || bad "CT 108 features are nesting=1,keyctl=1" "got: ${feat:-no answer from lenora}"
$SSH "root@$LENORA" 'pct config 108 | grep -q "^onboot: 1"' 2>/dev/null \
  && pass "CT 108 starts at boot" || bad "CT 108 starts at boot" "onboot is not 1"

echo "== engine"
$SSH "root@$HOST" 'systemctl is-active --quiet docker' \
  && pass "docker is active" || bad "docker is active" "unit not running"
for kv in "LoggingDriver journald" "LiveRestoreEnabled true"; do
  set -- $kv
  got=$($SSH "root@$HOST" "docker info --format '{{.$1}}'" 2>/dev/null)
  [[ "$got" == "$2" ]] && pass "docker $1 is $2" || bad "docker $1 is $2" "got: ${got:-nothing}"
done
# The real question behind all of the above: can this host run a container at
# all? Unprivileged LXC breaks that in ways a config check cannot see, and the
# pull proves egress at the same time.
if $SSH "root@$HOST" 'docker run --rm hello-world' 2>/dev/null | grep -q 'working correctly'; then
  pass "a container pulls, runs and exits"
else bad "a container pulls, runs and exits" "docker run hello-world did not produce its banner"; fi

echo "== engine metrics over TLS"
# 403 from here is the pass: nginx allows only Prometheus. A 200 would mean
# the allow list is gone.
https_ok "engine metrics on $HOST:9323" "https://$HOST:9323/metrics" 403
chain_ok "moby:9323" "$HOST:9323"
renewal_ok moby "$HOST"
# The engine's own listener is plain HTTP; the whole point of nginx here is
# that it is not reachable off-box.
if nc -z -G 2 "$HOST" 9324 2>/dev/null; then
  bad "engine metrics backend is loopback-only" "9324 is reachable from the LAN"
else pass "engine metrics backend is loopback-only"; fi
# Prometheus is allowed, and gets real metrics rather than nginx's 403 page.
if $SSH "root@$PROM" "curl -sS --max-time 10 --cacert /etc/homelab-tls/root_ca.crt https://$HOST:9323/metrics" 2>/dev/null \
     | grep -q '^engine_daemon_engine_info'; then
  pass "prometheus is allowed through and reads engine_daemon_engine_info"
else bad "prometheus is allowed through" "no engine_daemon_engine_info from .53"; fi

echo "== node-exporter"
https_ok "node-exporter on $HOST:9100" "https://$HOST:9100/metrics"

echo "== scraped by prometheus"
for job in node alloy docker traefik homeassistant; do
  $CURL "https://$PROM:9090/api/v1/targets" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
ok=[t for t in d['data']['activeTargets']
    if t['labels']['job']=='$job' and t['labels'].get('role')=='moby'
    and t['health']=='up']
sys.exit(0 if ok else 1)" \
    && pass "prometheus $job target for moby is up" \
    || bad "prometheus $job target for moby is up" "no healthy target - deploy prometheus/ or wait a scrape interval"
done

echo "== extra addresses and the stacks that publish on them"
# The addresses arrived with the stacks from the old moby; docker.service
# Requires= the unit that adds them, so a container binding .73 or .74 cannot
# start before they exist.
for a in 192.168.1.73 192.168.1.74 192.168.1.79; do
  $SSH "root@$HOST" "ip -4 addr show dev eth0 | grep -q 'inet $a/'" \
    && pass "$a is on eth0" || bad "$a is on eth0" "address missing - is homelab-extra-addresses running?"
done
$SSH "root@$HOST" 'systemctl is-enabled --quiet homelab-extra-addresses.service' \
  && pass "homelab-extra-addresses is enabled at boot" \
  || bad "homelab-extra-addresses is enabled at boot" "not enabled - the addresses will not survive a reboot"

# Nextcloud rejects a request whose Host is a bare IP (trusted_domains), so
# ask it the way a client does.
if curl -sS --max-time 15 -H 'Host: nextcloud.lan' http://192.168.1.73/status.php 2>/dev/null \
     | grep -q '"maintenance":false'; then
  pass "nextcloud answers on .73 and is not in maintenance mode"
else bad "nextcloud answers on .73" "status.php did not report a healthy install"; fi

# Traefik holds the routes for both migrated sites. Its API is plain HTTP on
# the dashboard entrypoint - see prometheus.yml.
routers=$(curl -sS --max-time 10 http://192.168.1.74:8080/api/http/routers 2>/dev/null \
  | python3 -c 'import json,sys; print(" ".join(r["name"] for r in json.load(sys.stdin) if r.get("status")=="enabled"))' 2>/dev/null || true)
for r in nextcloud_lan@docker xwiki@docker; do
  grep -q "$r" <<<"$routers" && pass "traefik router $r is enabled" \
    || bad "traefik router $r is enabled" "not in the enabled routers: ${routers:-none}"
done
code=$(curl -sk --max-time 30 -o /dev/null -w '%{http_code}' --resolve inall.net:443:192.168.1.74 https://inall.net/xwiki/ 2>/dev/null || echo 000)
case "$code" in
  200|302) pass "xwiki serves through traefik (http=$code)" ;;
  202)     warn "xwiki through traefik" "202 - tomcat is still starting" ;;
  *)       bad  "xwiki serves through traefik" "http=$code" ;;
esac

echo "== home assistant"
https_ok "home assistant on 192.168.1.79" "https://192.168.1.79/manifest.json"
chain_ok "moby:443 (.79)" "192.168.1.79:443"
# The UI is a websocket application: a proxy that serves the page and drops
# the upgrade looks like a broken backend, not a broken proxy. HTTP/1.1 on
# purpose - an upgrade over h2 is refused before nginx ever sees it.
if curl -sS --http1.1 --cacert "$CA_ROOT" -i --max-time 10 \
     -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
     -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
     --resolve homeassistant.home:443:192.168.1.79 \
     https://homeassistant.home/api/websocket 2>/dev/null | grep -q '101 Switching Protocols'; then
  pass "websocket upgrades through nginx (101)"
else bad "websocket upgrades through nginx" "no 101 - check the Upgrade/Connection headers"; fi
# nginx passes X-Forwarded-For, which Home Assistant answers with 400 unless
# 172.20.0.0/14 is a trusted proxy in its UI. A plain request proves the pair
# still agree; the manifest check above would pass either way, since curl
# sends no such header of its own.
code=$(curl -sS --cacert "$CA_ROOT" -o /dev/null -w '%{http_code}' --max-time 10 https://192.168.1.79/ 2>/dev/null || echo 000)
[[ "$code" == 200 ]] \
  && pass "home assistant accepts the proxy's X-Forwarded-For (200)" \
  || bad "home assistant accepts the proxy's X-Forwarded-For" \
        "http=$code - 400 means trusted_proxies/use_x_forwarded_for is off in its UI"

# 8123 belongs to the app and must stay on loopback; nginx is the only way in.
if nc -z -G 2 192.168.1.79 8123 2>/dev/null; then
  bad "home assistant backend is loopback-only" "8123 is reachable from the LAN"
else pass "home assistant backend is loopback-only"; fi

echo "== logs in loki"
n=$($CURL -G "https://$LOKI:3100/loki/api/v1/query" \
      --data-urlencode 'query=count_over_time({host="moby"}[15m])' 2>/dev/null \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(sum(int(v["value"][1]) for v in r))' 2>/dev/null || echo 0)
[[ ${n:-0} -gt 0 ]] && pass "loki has journal lines for host=\"moby\" ($n in 15m)" \
  || bad "loki has journal lines for host=\"moby\"" "nothing in the last 15m - is alloy up?"
# Container stdout only reaches Loki because the engine logs through journald
# and alloy/ promotes CONTAINER_NAME to a `container` label. With no stacks
# running yet there is nothing to find, which is not a failure.
running=$($SSH "root@$HOST" 'docker ps -q | wc -l' 2>/dev/null || echo 0)
if [[ ${running:-0} -eq 0 ]]; then
  warn "no container logs to check" "no containers running on moby yet"
else
  labels=$($CURL "https://$LOKI:3100/loki/api/v1/label/container/values" 2>/dev/null \
           | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("data") or []))' 2>/dev/null || echo 0)
  [[ ${labels:-0} -gt 0 ]] && pass "loki has a container label ($labels values)" \
    || bad "loki has a container label" "containers are running but none of their logs carry container="
fi

echo
[[ $fail -eq 0 ]] && echo "all checks passed" || { echo "$fail check(s) failed"; exit 1; }
