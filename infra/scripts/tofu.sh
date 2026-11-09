#!/usr/bin/env bash
# Run OpenTofu with the state database and Proxmox token set up, on a workstation
# or on talos. Arguments go straight to tofu:
#
#   infra/scripts/tofu.sh init
#   infra/scripts/tofu.sh plan
#
# The secrets are in Bitwarden; infra/scripts/vault.py pull writes them locally.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)

if [[ -r /etc/forgejo-runner/tofu.env ]]; then
  secrets=/etc/forgejo-runner/tofu.env
  root_ca=/etc/homelab-tls/root_ca.crt
else
  secrets=${HOMELAB_PRIVATE:-$HOME/projects/homelab-private}/tofu/secrets.env
  root_ca=$repo/ca/rootca/certs/root.crt
fi

value() { sed -n "s/^$1=//p" "$secrets"; }

PG_CONN_STR="postgres://tofu:$(value TOFU_STATE_PG_PASSWORD)@forgejo.home/tofu_state?sslmode=verify-full&sslrootcert=$root_ca"
TF_VAR_state_passphrase=$(value TOFU_STATE_PASSPHRASE)
PROXMOX_VE_API_TOKEN=$(value PROXMOX_VE_API_TOKEN)
export PG_CONN_STR TF_VAR_state_passphrase PROXMOX_VE_API_TOKEN

exec tofu -chdir="$repo/infra/tofu" "$@"
