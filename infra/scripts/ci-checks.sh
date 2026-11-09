#!/usr/bin/env bash
# The checks every push has to pass. Changes nothing, needs no credentials and
# reaches no host, so a person can run it anywhere the pinned tools are installed.
#
# The secret scan covers the full history, because a secret removed in a later
# commit is still published when the history is.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

failed=0
step() { # step <label> <command...>
  local label=$1; shift
  echo "== $label"
  if "$@"; then echo "   PASS"; else echo "   FAIL"; failed=$((failed + 1)); fi
}

scan_secrets() { gitleaks git --redact --no-banner --log-level warn --config .gitleaks.toml .; }
tofu_fmt() { tofu -chdir=infra/tofu fmt -check; }
# validate never reads state, so the encryption passphrase can be a stand-in.
tofu_validate() {
  export TF_VAR_state_passphrase=validate-only-placeholder
  tofu -chdir=infra/tofu init -backend=false -input=false >/dev/null && tofu -chdir=infra/tofu validate
}
ansible_lint() { (cd infra/ansible && ansible-lint --offline -q .); }
# Errors everywhere, and the stricter default for the code this programme adds.
shell_errors() { git ls-files -z '*.sh' | xargs -0 shellcheck -S error; }
shell_infra() { git ls-files -z 'infra/*.sh' 'talos/*.sh' | xargs -0 shellcheck -x -S warning; }
python_syntax() {
  git ls-files -z '*.py' | xargs -0 python3 -c '
import sys
bad = 0
for path in sys.argv[1:]:
    try:
        compile(open(path, "rb").read(), path, "exec")
    except SyntaxError as error:
        print(error)
        bad = 1
sys.exit(bad)'
}

step "no secrets in the history" scan_secrets
step "OpenTofu is formatted" tofu_fmt
step "OpenTofu is valid" tofu_validate
step "Ansible lint" ansible_lint
step "shell scripts have no errors" shell_errors
step "infra and talos scripts are clean" shell_infra
step "Python parses" python_syntax

echo
if ((failed)); then echo "$failed check(s) failed"; exit 1; fi
echo "all checks passed"
