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
2. `ansible-playbook ci.yml --limit talos` from `infra/ansible`, then `fleet.yml`
   limited to it, and `responder/scripts/hosts.sh`.
3. A rebuilt `talos` has new keys. A person adds the new
   `/var/lib/forgejo-runner/.ssh/github.pub` to the GitHub repository as a deploy key
   with write access and removes the old one, copies `.ssh/pistis-mint.pub` over
   `talos/pistis-mint.pub`, and runs `ansible-playbook ca.yml`.
4. `scripts/verify.sh`.

## Invariants

1. **Publishing to GitHub happens only after the checks pass on `main`.** The
   publish step comes last in the job, so a failed scan stops it. Forgejo's
   built-in push mirror must not be used: it pushes without waiting for checks,
   and GitHub is public.

2. **Registered for one repository.** A wider scope would let any other
   repository's workflow use the GitHub key.

3. **The only write access here is the GitHub key, OpenTofu's state and minting
   tokens for new hosts or re-issuing the reachable ones with approved names.**
   `verify.sh` asserts those two keys are the only ones.
   The keys never leave this host, and the runner's own secret is made here too,
   so none is in Bitwarden: a rebuild makes new ones. The minting key is forced to
   `homelab-mint-token --restricted` on pistis (`ca/CLAUDE.md`). `/etc/forgejo-runner/tofu.env` holds the state
   database password and passphrase and a Proxmox token that can only read.

4. **Never force-push to GitHub.** If GitHub has commits Forgejo lacks, the
   publish step fails and a person reconciles it. ruby and jennie pull from
   GitHub.
