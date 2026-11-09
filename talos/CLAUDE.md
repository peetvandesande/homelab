# talos

CT 111, `talos.home`. The deploy runner for this repository: a Forgejo Actions
runner in host mode, label `talos`, registered for `peet/homelab` only. Separate
from lexie's runner because everything an account holds is available to every
workflow it runs, and lexie's runs the job search repositories too.

Today it runs the checks and publishes to GitHub. It gets deploy credentials at
task 13 in `infra/README.md`, and not before.

`.forgejo/workflows/checks.yml` drives it; `infra/scripts/ci-checks.sh` holds the
checks, so a person can run them without the runner.

## Rebuilding

1. Reservation, `pct create`, then `ca/scripts/enrol.sh 192.168.8.59 talos`.
2. `scripts/bootstrap.sh`, which prints a new public key. A person adds it to
   the GitHub repository as a deploy key with write access, and removes the old.
3. `scripts/deploy.sh`, then the fleet deploys for `node-exporter/`, `alloy/`,
   `apt/`, `fleet/` and `responder/scripts/hosts.sh`.
4. `scripts/verify.sh`.

## Invariants

1. **Publishing to GitHub happens only after the checks pass on `main`.** The
   publish step comes last in the job, so a failed scan stops it. Forgejo's
   built-in push mirror must not be used: it pushes without waiting for checks,
   and GitHub is public.

2. **Registered for one repository.** A wider scope would let any other
   repository's workflow use the GitHub key.

3. **The only credential here is the GitHub key.** `verify.sh` asserts it. The
   key never leaves this host, and the runner's own secret is made here too, so
   neither is in Bitwarden: a rebuild makes new ones.

4. **Never force-push to GitHub.** If GitHub has commits Forgejo lacks, the
   publish step fails and a person reconciles it. ruby and jennie pull from
   GitHub.
