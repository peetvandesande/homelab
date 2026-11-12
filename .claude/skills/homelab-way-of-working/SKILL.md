---
name: homelab-way-of-working
description: How to make any change in ~/projects/homelab – Ansible roles and OpenTofu, deployed by the Forgejo runners on merge, with no or minimal custom scripts. Load before planning or building anything in that repo, and before handing the user steps to run.
---

# Working in the homelab

The estate is moving to self-running: Git is the desired state, Ansible and
OpenTofu converge it, and the Forgejo runners apply it on merge. A change is
finished when it is merged and the runner has applied it – not when a script
has been run by hand. The record is `infra/README.md`: intent, decisions,
tasks, and a dated "Where it stands" list under Tasks.

## The rule: declarative, run by the runners

- **Configuration lives in Ansible roles** (`infra/ansible/roles/<name>/`,
  sourcing files from `<service>/root/`, which mirrors the host) **or in
  OpenTofu** (`infra/tofu/`). Nothing else is a source of truth.
- **The runners deploy.** On `main`, after the checks, `talos` runs
  `infra/scripts/apply.sh` (the playbooks whose sources changed) and
  `infra/scripts/tofu-apply.sh` (OpenTofu). A role is only deployed on merge if
  `apply.sh` runs its playbook – check that when adding one.
- **No new custom scripts**, and none extended, as a way to deploy: no
  `*/scripts/install-*.sh`, `deploy.sh`, `enrol.sh`-style steps. If something
  is only managed by a script today, move it into a role or Tofu first.
- **No "run this after merge" steps** in a PR or a reply. If a merge needs a
  manual act, the design is not finished.
- **A script is acceptable only as a program the roles install** – a service's
  own executable, timer job or check (`homelab-security-reboot`,
  `estate-weekly`) – stdlib Python or plain shell, with tests in `tests/` wired
  into `infra/scripts/ci-checks.sh`. Keep even those minimal.
- **Shadow first.** Anything that acts on its own (reboots, runbooks, the
  responder's PRs) ships recording what it would do, and goes live per host by
  a later PR for the owner.

## Where the runner cannot reach

`pistis`, `lenora`, `talos`, `lexie`, `ruby` and `jennie` are deliberately out
of `apply.sh`'s reach; it prints a change to them for a person. Do not fall back
to a script for these. Either:

- the change is a role in a person-run playbook (`ci.yml`, `platform.yml`,
  `ca.yml`, `outside.yml`), and the reply names that one playbook and its
  `--limit`; or
- the trust boundary itself is the problem – raise it with the user before
  building around it.

ruby and jennie: `ansible-playbook -i inventory/outside.yml outside.yml
--ask-become-pass --limit <host>`, run by the user from
`/Users/peet/projects/homelab` – so `git pull` main there first. Never probe
sudo on ruby; hand the user sudo commands.

The router, the ONT and Home Assistant OS cannot be managed by Ansible: they
stay documented (`router/`) with the few person-run deploys listed in
`infra/README.md`, "Kept out of the automation". Do not add to that list
without asking.

## How a change lands

1. **Check the checkout first.** Another session may be working in it: if the
   branch is not `main` or the tree is dirty with files you did not touch, do
   not switch, stash or commit them – stop and ask, or use a `git worktree`
   only if the user agrees.
2. Branch, commit (`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`),
   push to Forgejo `origin` only, as `homelab-bot`: the token is
   `FORGEJO_TOKEN` in `~/projects/homelab-private/forgejo-automation.env`,
   passed via `GIT_CONFIG_*` http.extraHeader and `curl -K -`, never argv or
   output. `--cacert ca/rootca/certs/root.crt`.
3. Open the PR by API, wait for `checks / checks (push)`, then merge
   (`{"Do":"rebase","delete_branch_after_merge":true}`) – **unless** it is
   material: exposes a service, touches an outward-facing path, or changes
   ruby, jennie, the router or a reboot/act-on-its-own policy. Those are opened
   and left for the owner. Never force-push; never push to GitHub.
4. Confirm the runner applied it (the host's state, not just a green run).

## Secrets

Bitwarden is the source of truth; `~/projects/homelab-private/` is its cache.
For a new secret: add names to `infra/secrets/manifest`, write an empty
`homelab-private/<svc>/secrets.env` (mode 600, `VAR=` lines), and the user
fills it and runs `infra/scripts/vault.py import`. Restricted secrets go only
through person-run playbooks. Never print a value.

## Every change

- Monitored in the same change (metrics, logs, an alert), and recorded in the
  action log if it acts (`infra/scripts/action-log`, start before acting).
- Docs updated where the next person looks: the service's `CLAUDE.md`, the
  task row in `infra/README.md`. Names, not IPs; config comments
  self-contained.
- Check it against the intent in `infra/README.md`; one task, one checkpoint.
- British English, en-dashes, short replies.
