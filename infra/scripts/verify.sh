#!/usr/bin/env bash
# Is infra/ usable from this machine? Changes nothing on any host.
# hermes is switched off when no Proxmox lab is running, so it alone may be
# unreachable.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
# shellcheck disable=SC1091
source versions.env

failed=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; failed=$((failed + 1)); }
check_eq() { # check_eq <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1 ($3)"; else fail "$1: expected '$2', got '$3'"; fi
}

echo "== tools"
check_eq "OpenTofu version" "$TOFU_VERSION" \
  "$(tofu version | sed -n 's/^OpenTofu v//p' | head -1)"
check_eq "ansible-core version" "$ANSIBLE_CORE_VERSION" \
  "$(ansible --version | sed -n 's/^ansible \[core \(.*\)\]$/\1/p')"

check_eq "bws version" "bws $BWS_VERSION" "$(bws --version)"

echo "== OpenTofu"
if tofu -chdir=tofu fmt -check >/dev/null; then pass "formatted"; else fail "tofu fmt -check"; fi
if tofu -chdir=tofu init -backend=false -input=false >/dev/null \
  && tofu -chdir=tofu validate >/dev/null; then
  pass "configuration is valid"
else
  fail "tofu init or validate"
fi

echo "== Ansible"
cd ansible || exit 1
inventory=$(./inventory/fleet.py | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)["fleet"]["hosts"]))')
expected=$(sed -n '/^FLEET=(/,/^)/p' ../../ca/scripts/enrol.sh | grep -cE '^[[:space:]]*"[0-9]')
check_eq "inventory matches FLEET" "$expected" "$inventory"

output=$(ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1 ansible fleet -m ansible.builtin.ping 2>&1)
reached=$(grep -c ' | SUCCESS' <<<"$output")
changed=$(grep -cE '"?changed"?: true' <<<"$output")
missing=$(grep -E ' \| (UNREACHABLE|FAILED)' <<<"$output" | cut -d' ' -f1 | sort | tr '\n' ' ')
check_eq "no host reports a change" "0" "$changed"
case "${missing% }" in
  "")     pass "all $reached hosts reached" ;;
  hermes) pass "$reached hosts reached, hermes off" ;;
  *)      fail "unreachable or failed: $missing"; grep -E 'UNREACHABLE|FAILED' <<<"$output" | cut -c1-200 ;;
esac

echo
if ((failed)); then echo "$failed check(s) failed"; exit 1; fi
echo "all checks passed"
