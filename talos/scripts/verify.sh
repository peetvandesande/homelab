#!/usr/bin/env bash
# fail is set by verify-lib.sh, sourced below.
# shellcheck disable=SC2154
cd "$(dirname "$0")/.." || exit 1
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
# shellcheck disable=SC1091
source ../infra/versions.env
HOST=192.168.8.59
on() { ssh -o BatchMode=yes "root@$HOST" "$@" 2>/dev/null; }

echo "== runner"
[[ $(on systemctl is-active forgejo-runner) == active ]] && pass "forgejo-runner is active" \
  || bad "forgejo-runner is active" "$(on systemctl is-active forgejo-runner)"
renewal_ok talos "$HOST"

echo "== pinned tools"
check() { [[ $2 == "$3" ]] && pass "$1 $2" || bad "$1 $2" "$3"; }
check tofu "$TOFU_VERSION" "$(on tofu version | sed -n 's/^OpenTofu v//p' | head -1)"
check gitleaks "$GITLEAKS_VERSION" "$(on gitleaks version)"
check ansible-core "$ANSIBLE_CORE_VERSION" "$(on ansible --version | sed -n 's/^ansible \[core \(.*\)\]$/\1/p')"

echo "== what a job can reach: only the GitHub key"
keys=$(on 'ls /var/lib/forgejo-runner/.ssh | tr "\n" " "')
[[ $keys == "config github github.pub known_hosts " ]] && pass "the account holds only the GitHub key" \
  || bad "the account holds only the GitHub key" "$keys"
groups=$(on id -Gn forgejo-runner)
[[ $groups == forgejo-runner ]] && pass "no group beyond its own" || bad "no group beyond its own" "$groups"
on 'test ! -e /etc/sudoers.d/forgejo-runner && ! command -v bws >/dev/null' \
  && pass "no sudo rule, no Bitwarden client" || bad "no sudo rule, no Bitwarden client" "found"

echo; (( fail )) && echo "$fail check(s) failed" || echo "all checks passed"; exit $fail
