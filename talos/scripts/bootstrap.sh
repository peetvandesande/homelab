#!/usr/bin/env bash
# Prepare talos: packages, the pinned CI tools, the runner account and its
# GitHub key. Run after ca/scripts/enrol.sh, before scripts/deploy.sh. Safe to
# re-run. A rebuilt talos gets a new GitHub key, which a person has to add to
# the repository as a deploy key.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/lib.sh
# shellcheck disable=SC1091
source ../infra/versions.env
HOST=192.168.8.59
GITHUB_HOST_KEY='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'

require_enrolled "$HOST"

$SSH "root@$HOST" "
  tofu=$TOFU_VERSION tofu_sum=$TOFU_SHA256_LINUX_AMD64
  gitleaks=$GITLEAKS_VERSION gitleaks_sum=$GITLEAKS_SHA256_LINUX_AMD64
  core=$ANSIBLE_CORE_VERSION lint=$ANSIBLE_LINT_VERSION
  github_key='$GITHUB_HOST_KEY'
  pistis_key='$(grep '^192.168.8.55 ' ../infra/ansible/known_hosts)'
"'
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends git curl unzip openssl python3-venv shellcheck \
    prometheus-node-exporter >/dev/null

  # A release archive, refused unless it matches the pinned sum.
  fetch() { # fetch <url> <sha256> <path>
    curl -fsSL -o "$3" "$1"
    echo "$2  $3" | sha256sum -c --quiet
  }
  tmp=$(mktemp -d)
  trap "rm -rf $tmp" EXIT

  if ! tofu version 2>/dev/null | grep -q "^OpenTofu v$tofu\$"; then
    fetch "https://github.com/opentofu/opentofu/releases/download/v$tofu/tofu_${tofu}_linux_amd64.zip" "$tofu_sum" "$tmp/tofu.zip"
    unzip -q -o -d "$tmp/tofu" "$tmp/tofu.zip" tofu
    install -m 0755 "$tmp/tofu/tofu" /usr/local/bin/tofu
  fi
  if ! gitleaks version 2>/dev/null | grep -qx "$gitleaks"; then
    fetch "https://github.com/gitleaks/gitleaks/releases/download/v$gitleaks/gitleaks_${gitleaks}_linux_x64.tar.gz" "$gitleaks_sum" "$tmp/gitleaks.tgz"
    tar -xzf "$tmp/gitleaks.tgz" -C "$tmp" gitleaks
    install -m 0755 "$tmp/gitleaks" /usr/local/bin/gitleaks
  fi

  # Ansible from PyPI, as Debian packages an older ansible-core than the lab uses.
  [ -x /opt/ci/bin/pip ] || python3 -m venv /opt/ci
  /opt/ci/bin/pip install -q "ansible-core==$core" "ansible-lint==$lint"
  ln -sf /opt/ci/bin/ansible-lint /usr/local/bin/ansible-lint
  ln -sf /opt/ci/bin/ansible /usr/local/bin/ansible

  getent passwd forgejo-runner >/dev/null \
    || useradd --system --create-home --home-dir /var/lib/forgejo-runner --shell /usr/sbin/nologin \
         --comment "Forgejo Actions runner" forgejo-runner
  h=/var/lib/forgejo-runner
  install -d -o forgejo-runner -g forgejo-runner -m 0750 $h $h/work
  install -d -o forgejo-runner -g forgejo-runner -m 0700 $h/.ssh
  [ -f $h/.ssh/github ] || runuser -u forgejo-runner -- \
    ssh-keygen -q -t ed25519 -N "" -C forgejo-runner@talos -f $h/.ssh/github
  # Forced on pistis to homelab-mint-token, so this key can mint tokens for new
  # hosts and do nothing else.
  [ -f $h/.ssh/pistis-mint ] || runuser -u forgejo-runner -- \
    ssh-keygen -q -t ed25519 -N "" -C forgejo-runner@talos-mint -f $h/.ssh/pistis-mint
  printf "Host github.com\n  User git\n  IdentityFile %s/.ssh/github\n  IdentitiesOnly yes\n  StrictHostKeyChecking yes\n  UpdateHostKeys no\n\nHost pistis-mint\n  HostName 192.168.8.55\n  User root\n  IdentityFile %s/.ssh/pistis-mint\n  IdentitiesOnly yes\n  StrictHostKeyChecking yes\n  UpdateHostKeys no\n" "$h" "$h" > $h/.ssh/config
  # GitHub'"'"'s published key, so the first push trusts nothing it is told.
  printf "%s\n%s\n" "$github_key" "$pistis_key" > $h/.ssh/known_hosts
  rm -f $h/.ssh/known_hosts.old
  chown forgejo-runner:forgejo-runner $h/.ssh/config $h/.ssh/known_hosts
  chmod 0600 $h/.ssh/config $h/.ssh/known_hosts
'
echo "   tools and account ready"
echo "   deploy key for GitHub:"
$SSH "root@$HOST" 'cat /var/lib/forgejo-runner/.ssh/github.pub'
# Committed, because the step_ca role installs it on pistis.
$SSH "root@$HOST" 'cat /var/lib/forgejo-runner/.ssh/pistis-mint.pub' > pistis-mint.pub
echo "   minting key written to talos/pistis-mint.pub; run ansible-playbook ca.yml"
