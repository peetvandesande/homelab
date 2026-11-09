#!/usr/bin/env bash
# Backups from lenora to sally: retention and maintenance on sally, a backup-only
# token, encrypted storage and the nightly job on lenora. Safe to re-run.
#
# lenora's token can add backups but cannot delete them, so pruning happens on
# sally. The encryption key is made on lenora and copied to the private cache,
# from which infra/scripts/vault.py import puts it in Bitwarden. Without that
# key the backups cannot be read, so run the import straight after a first run.
# On a rebuilt lenora, run vault.py pull first: the key in the cache is reused,
# and a new one would make every existing backup unreadable.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
SALLY=192.168.8.22
LENORA=192.168.8.21
STORE=hddpool
AUTH='lenora-backup@pbs'
TOKEN="$AUTH!nightly"
KEY_COPY=${HOMELAB_PRIVATE:-$HOME/projects/homelab-private}/pbs/sally-encryption.enc
# Every guest but the disposable lab VMs. A new guest must be added here;
# homelab-backup-hook publishes a zero for one that is not, and that alerts.
GUESTS=100,101,102,103,104,105,106,107,108,109,110,111,300,301,302,303

echo "== sally: retention and maintenance"
$SSH "root@$SALLY" "store=$STORE auth='$AUTH' token='$TOKEN'"'
  set -e
  pm=proxmox-backup-manager
  $pm user list --output-format json | grep -q "\"userid\":\"$auth\"" || $pm user create "$auth" --comment "lenora nightly backups"
  $pm prune-job list --output-format json | grep -q "\"id\":\"daily\"" ||
    $pm prune-job create daily --store "$store" --schedule 04:30 --keep-daily 7 --keep-weekly 4 --keep-monthly 6
  $pm verify-job list --output-format json | grep -q "\"id\":\"weekly\"" ||
    $pm verify-job create weekly --store "$store" --schedule "sun 05:00" --ignore-verified true --outdated-after 30
  $pm datastore update "$store" --gc-schedule 04:45
'
echo "   prune 7/4/6, garbage collection, weekly verify"

echo "== lenora: storage, hook and job"
push "$LENORA" lenora
$SSH "root@$LENORA" 'install -d -m 0755 /var/lib/homelab-backup; chmod +x /usr/local/bin/homelab-backup-hook /usr/local/bin/homelab-backup-restore-test'

if ! $SSH "root@$LENORA" 'pvesm status --storage sally >/dev/null 2>&1'; then
  key=autogen
  if [[ -s $KEY_COPY ]]; then
    $SSH "root@$LENORA" 'umask 077; cat > /root/sally.enc.new' < "$KEY_COPY"
    key=/root/sally.enc.new
  fi
  # The token is shown once, when it is made, and goes straight to lenora.
  $SSH "root@$SALLY" "store=$STORE auth='$AUTH' token='$TOKEN'"'
    set -e
    pm=proxmox-backup-manager
    $pm user delete-token "$auth" nightly >/dev/null 2>&1 || true
    value=$($pm user generate-token "$auth" nightly | sed "s/^Result: //" | jq -r .value)
    [ -n "$value" ] && [ "$value" != null ]
    # A token has the smaller of its own rights and its user'"'"'s, so both need it.
    $pm acl update "/datastore/$store" DatastoreBackup --auth-id "$auth" >/dev/null
    $pm acl update "/datastore/$store" DatastoreBackup --auth-id "$token" >/dev/null
    printf "%s\n" "$value"
  ' | $SSH "root@$LENORA" "store=$STORE token='$TOKEN' key=$key"'
    set -e
    read -r value
    # No fingerprint: certificates renew, and lenora trusts the lab root.
    pvesm add pbs sally --server sally.home --datastore "$store" --username "$token" \
      --password "$value" --encryption-key "$key" --content backup --prune-backups keep-all=1
    rm -f /root/sally.enc.new
  '
  echo "   storage added"
fi

if [[ -s $KEY_COPY ]]; then
  # Never replace a saved key: it is what reads the existing backups.
  $SSH "root@$LENORA" 'cat /etc/pve/priv/storage/sally.enc' | cmp -s - "$KEY_COPY" \
    || { echo "lenora's encryption key differs from the saved one; stopping"; exit 1; }
  echo "   encryption key matches the saved copy"
else
  mkdir -p "$(dirname "$KEY_COPY")"
  ( umask 077; $SSH "root@$LENORA" 'cat /etc/pve/priv/storage/sally.enc' > "$KEY_COPY" )
  [[ -s $KEY_COPY ]] || { echo "could not copy the encryption key"; exit 1; }
  echo "   encryption key copied to the private cache; run infra/scripts/vault.py import"
fi

$SSH "root@$LENORA" "guests=$GUESTS"'
  set -e
  args=(--schedule 03:30 --storage sally --vmid "$guests" --mode snapshot --enabled 1
        --script /usr/local/bin/homelab-backup-hook --mailnotification failure)
  if pvesh get /cluster/backup/sally-nightly >/dev/null 2>&1; then
    pvesh set /cluster/backup/sally-nightly "${args[@]}"
  else
    pvesh create /cluster/backup --id sally-nightly "${args[@]}"
  fi
'
echo "   nightly job set for 03:30"
