#!/usr/bin/env bash
# Checks the intent of moby/: a Docker host that can actually run containers,
# whose engine metrics are TLS off the lab CA, and whose containers' logs
# reach Loki. Read-only - it pulls and runs one throwaway container.
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.8.27
LENORA=192.168.8.21
PROM=192.168.8.53
LOKI=192.168.8.56
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
for job in node alloy docker traefik n8n; do
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
for a in 192.168.8.73 192.168.8.74; do
  $SSH "root@$HOST" "ip -4 addr show dev eth0 | grep -q 'inet $a/'" \
    && pass "$a is on eth0" || bad "$a is on eth0" "address missing - is homelab-extra-addresses running?"
done
$SSH "root@$HOST" 'systemctl is-enabled --quiet homelab-extra-addresses.service' \
  && pass "homelab-extra-addresses is enabled at boot" \
  || bad "homelab-extra-addresses is enabled at boot" "not enabled - the addresses will not survive a reboot"

# Nextcloud rejects a request whose Host is a bare IP (trusted_domains), so
# ask it the way a client does.
if curl -sS --max-time 15 -H 'Host: nextcloud.lan' http://192.168.8.73/status.php 2>/dev/null \
     | grep -q '"maintenance":false'; then
  pass "nextcloud answers on .73 and is not in maintenance mode"
else bad "nextcloud answers on .73" "status.php did not report a healthy install"; fi

# Traefik holds the routes for both migrated sites. Its API is plain HTTP on
# the dashboard entrypoint - see prometheus.yml.
routers=$(curl -sS --max-time 10 http://192.168.8.74:8080/api/http/routers 2>/dev/null \
  | python3 -c 'import json,sys; print(" ".join(r["name"] for r in json.load(sys.stdin) if r.get("status")=="enabled"))' 2>/dev/null || true)
for r in nextcloud_lan@docker xwiki@docker; do
  grep -q "$r" <<<"$routers" && pass "traefik router $r is enabled" \
    || bad "traefik router $r is enabled" "not in the enabled routers: ${routers:-none}"
done
code=$(curl -sk --max-time 30 -o /dev/null -w '%{http_code}' --resolve inall.net:443:192.168.8.74 https://inall.net/xwiki/ 2>/dev/null || echo 000)
case "$code" in
  200|302) pass "xwiki serves through traefik (http=$code)" ;;
  202)     warn "xwiki through traefik" "202 - tomcat is still starting" ;;
  *)       bad  "xwiki serves through traefik" "http=$code" ;;
esac

echo "== n8n, the repo-owned stack"
N8N=n8n.peetvandesande.com
$SSH "root@$HOST" 'cd /opt/stacks/n8n && docker compose ps --status running --services | grep -cxE "n8n|db"' 2>/dev/null | grep -qx 2 \
  && pass "n8n and its database are running" || bad "n8n and its database are running" "docker compose ps in /opt/stacks/n8n"
https_ok "$N8N/healthz (split-horizon to moby)" "https://$N8N/healthz"
code=$(curl -6 -sS --max-time 10 --cacert "$CA_ROOT" -o /dev/null -w '%{http_code}' "https://$N8N/healthz" 2>/dev/null) || code=000
[[ $code == 200 ]] && pass "$N8N over IPv6 (200)" || bad "$N8N over IPv6" "http=$code"
chain_ok "moby:443 (n8n)" "$HOST:443"
https_ok "n8n /metrics refused off Prometheus" "https://$N8N/metrics" 403
if nc -z -G 2 "$HOST" 5678 2>/dev/null; then bad "n8n's 5678 is loopback-only" "reachable from the LAN"
else pass "n8n's 5678 is loopback-only"; fi
# Through ruby, pinned to its public address. Webhooks reach n8n (its own 404
# for an unregistered path); the editor does not.
body=$(curl -sS --max-time 15 --resolve "$N8N:443:145.239.73.18" "https://$N8N/webhook/verify-probe" 2>/dev/null)
grep -q 'not registered' <<<"$body" && pass "webhooks reach n8n via ruby" \
  || bad "webhooks reach n8n via ruby" "${body:0:80} - is moby/scripts/install-ruby.sh installed on ruby?"
code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' --resolve "$N8N:443:145.239.73.18" "https://$N8N/" 2>/dev/null) || code=000
[[ $code == 403 ]] && pass "the editor is closed via ruby (403)" || bad "the editor is closed via ruby" "http=$code"

# Instance AI's sandbox service: the API healthy, the runner registered and
# able to start a container, nothing published.
$SSH "root@$HOST" 'docker inspect -f "{{.State.Health.Status}}" n8n-sandbox-api-1' 2>/dev/null | grep -qx healthy \
  && pass "sandbox-api is healthy" || bad "sandbox-api is healthy" "docker logs n8n-sandbox-api-1"
$SSH "root@$HOST" 'docker exec n8n-n8n-1 wget -qO- http://sandbox-api:8080/healthz' 2>/dev/null | grep -q ok \
  && pass "n8n reaches sandbox-api by name" || bad "n8n reaches sandbox-api by name" "same compose network?"
$SSH "root@$HOST" 'docker exec n8n-sandbox-runner-1-1 docker info -f "{{.ServerVersion}}"' >/dev/null 2>&1 \
  && pass "the sandbox runner's inner Docker is up" || bad "the sandbox runner's inner Docker is up" "docker logs n8n-sandbox-runner-1-1"
$SSH "root@$HOST" 'docker ps --filter label=com.docker.compose.project=n8n --format "{{.Ports}}" | grep -E "0\.0\.0\.0|\[::\]"' >/dev/null 2>&1 \
  && bad "nothing in the n8n stack is published beyond loopback" "a port is on the wildcard" \
  || pass "nothing in the n8n stack is published beyond loopback"

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
