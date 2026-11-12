#!/usr/bin/env bash
# Applies one merge to main: runs only the playbooks whose sources changed, in the
# order the services depend on each other. Called by CI after the checks pass.
#
#   apply.sh <old-commit> <new-commit>            apply
#   apply.sh --plan <old-commit> <new-commit>     print what would run, touch nothing
#
# Does nothing until a person has run infra/ansible/deploy-access.yml, which is what
# gives talos a key and the secrets. Hosts holding the keys to everything else stay
# out of reach of this: pistis (the CA), lenora (the hypervisor), talos and lexie
# (the runners and the responder), and ruby and jennie. A change to those is printed
# for a person to apply.
#
# Certificates are the exception that proves it: enrol.yml re-issues a reachable
# host whose names differ from FLEET, through talos's key on pistis, which only
# allows the names a person approved there with ca.yml.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

plan=0
[[ ${1:-} == --plan ]] && { plan=1; shift; }
old=${1:-}; new=${2:-}
DEPLOY=/etc/forgejo-runner/deploy
# Baseline hosts the runner never reaches. hermes is off unless a lab is running.
LIMIT='!pistis:!lenora:!talos:!lexie:!hermes'

if [[ -z $old || -z $new ]] || ! git rev-parse -q --verify "$old^{commit}" >/dev/null \
   || [[ $old =~ ^0+$ ]]; then
  echo "no previous commit to compare with; nothing to apply"
  exit 0
fi
mapfile -t changed < <(git diff --name-only "$old" "$new")

matches() { printf '%s\n' "${changed[@]}" | grep -qE "$1"; }
roles() { printf '^infra/ansible/roles/(%s)/' "$1"; }

need=()
matches "^ca/scripts/enrol\.sh$|$(roles 'enrol')|^infra/ansible/enrol\.yml" && need+=(enrol)
# A FLEET change can be a new host, which needs the baseline as well as a certificate.
matches "^ca/scripts/enrol\.sh$|^(alloy/root|apt/|fleet/|node-exporter/)|$(roles 'node_exporter|hygiene|apt_security|alloy')|^infra/ansible/fleet\.yml" && need+=(fleet)
# DNS before monitoring: a new host's name must exist before Prometheus first
# asks for it, or Themis caches the NXDOMAIN for the zone's negative TTL, an hour.
matches "^dns/(pythia|delphi|themis|ansible)/|$(roles 'dns_stack')|^infra/ansible/dns\.yml" && need+=(dns)
matches "^(prometheus|loki|grafana)/root/|$(roles 'prometheus|loki|grafana')|^infra/ansible/monitoring\.yml" && need+=(monitoring)
matches "^(jellyfin|navidrome|moby|glpi|forgejo)/root/|$(roles 'jellyfin|navidrome|moby|glpi|forgejo')|^infra/ansible/apps\.yml" && need+=(apps)
matches "^metis/root/|$(roles 'metis')" && need+=(metis)

person=$(printf '%s\n' "${changed[@]}" | grep -E \
  "^(ca|responder|runbooks|offsite|forgejo-runner|talos|outside|estate-report|github-alerts|wireguard|router|wan-watchdog|wifi-watchdog|appletv-uk|proxmox|shared|hermes)/|^(forgejo|moby)/ruby/|^alloy/outside/|^(router-metrics|homeassistant|sally)/|$(roles 'step_ca|responder|runbook|offsite|estate_report|github_alerts|forgejo_runner|talos|outside_host|lenora|hermes')|^infra/ansible/(ca|ci|offsite|outside|platform|deploy-access)\.yml" \
  | grep -vx 'ca/scripts/enrol\.sh' || true)
if [[ -n $person ]]; then
  echo "== needs a person: these do not reach their hosts through CI"
  printf '%s\n' "$person" | sed 's/^/   /'
fi

if ((${#need[@]} == 0)); then
  echo "== no playbook to run"
  exit 0
fi
echo "== to apply: ${need[*]}"
((plan)) && exit 0

if [[ ! -r $DEPLOY/key ]]; then
  echo "== apply is not enabled on this runner (see infra/ansible/deploy-access.yml); skipping"
  exit 0
fi
export ANSIBLE_PRIVATE_KEY_FILE=$DEPLOY/key HOMELAB_PRIVATE=$DEPLOY/private
export HOMELAB_DNS_SECRETS=$DEPLOY/private/dns/secrets.env
# Tells a role it runs from here, so it skips what only a person's run can reach.
export HOMELAB_APPLY_ON_MERGE=1
export PATH=/opt/ci/bin:$PATH
log=$PWD/infra/scripts/action-log
cd infra/ansible || exit 1

# run <name> <targets> <ansible-playbook arguments>. Nothing is applied unless the
# action can be recorded first.
run() {
  local name=playbook:$1 targets=$2 id
  shift 2
  echo "== ansible-playbook $*"
  id=$("$log" start --action "$name" --targets "$targets") \
    || { echo "== cannot write the action log; refusing to apply"; exit 1; }
  if ansible-playbook "$@"; then
    "$log" end "$id" --action "$name" succeeded || exit 1
  else
    "$log" end "$id" --action "$name" failed
    exit 1
  fi
}
for item in "${need[@]}"; do
  case $item in
    # pistis-mint is talos's forced-command key: the arguments are the request.
    enrol) run enrol "$LIMIT" enrol.yml --limit "$LIMIT" -e '{"enrol_minter": ["ssh", "pistis-mint"]}' ;;
    fleet) run fleet "$LIMIT" fleet.yml --limit "$LIMIT" ;;
    monitoring) run monitoring prometheus,loki,grafana monitoring.yml ;;
    dns) run dns pythia,delphi,themis dns.yml ;;
    apps) run apps jellyfin,navidrome,moby,glpi,forgejo apps.yml ;;
    metis) run metis metis platform.yml --limit metis ;;
  esac
done
echo "== applied"
