# infra

The programme that makes this estate run itself while staying something a
person can take over at any moment. OpenTofu owns the guests, Ansible owns what
is on them, and Git is how desired state changes. This file records the intent
and the decisions behind it, so a later change can be checked against them.

## Intent

Routine operations run without a person, and at any time someone can take over
using only this repo, OpenTofu, Ansible and Git.

Success means all four of these:

- routine operations run hands-off for a sustained period
- a person completes a real change and a real incident from the repo and docs alone
- every automated action traces to a trigger, a runbook, a commit and an outcome
- a weekly email lists incidents resolved and actions taken

## Decisions

| Area | Decision |
|---|---|
| Scope | The whole estate; Sogode's services are part of it |
| Operating model | Shared: people and the agent work on the same repo and pipelines |
| Known alerts | Exact-match rules run approved runbooks, with no LLM involved, so they work with the WAN down |
| Anything else | Claude Code investigates and advises, and may run allowlisted runbooks |
| What runbooks may do | Cause outages or destroy data if written to, so destructive ones snapshot first |
| Desired state | Changes only through Git and CI; runbooks do operational acts live and log each one |
| Merging | The agent merges its own changes when checks pass |
| Git home | Forgejo primary, mirrored to GitHub, with a separate deploy runner acting only on `main` |
| Restarts | Staggered service restarts by runbook, DNS hosts one at a time |
| Reboots | lenora, ruby and jennie may reboot unattended only for security updates, after a successful backup, before 06:00, with the reason recorded and service restoration verified afterwards (decided 10 November 2026) |
| Order | Full migration to OpenTofu and Ansible first, then autonomy |
| Backups | Proxmox Backup Server on sally, a dedicated Dell, out of the agent's reach; ruby and jennie rely on OVH's daily snapshots |
| Secrets | Bitwarden Secrets Manager is the source of truth; `~/projects/homelab-private` is a cache of it. No encrypted copy in Git, and no separate break-glass export for now, by choice |
| Weekly email | A new section of `estate-report`, sent only to the owner |

**Never without a person:** exposing secrets or services, and outward-facing
actions. The limits are enforced by what each account can do, not by what a
prompt says, because alert text carries untrusted log lines.

The agent merging its own work needs a condition, because `main` is mirrored to
a public repository: a merged secret is published. The required checks must
include secret scanning, and any change that exposes a service or touches an
outward-facing path must wait for a person.

The router and Home Assistant OS cannot be fully managed by Ansible, so they
stay documented or specially handled.

ruby and jennie run themselves day to day, security updates and the reboots above
included. A material change to them – configuration, a new service, firewall or
mail settings – lands by pull request with the owner's approval. So does a
material change anywhere else in the estate.

## Changing main

`main` is protected, administrators included: changes land by pull request, and only
once `checks / checks (push)`, which includes the secret scan, has passed on a branch
that is up to date with `main`. No approval is required, so automation can merge its
own work. A change that exposes a service or touches an outward-facing path still
waits for a person, even when the checks pass.

## Landing a change

Every change, to a guest or anything else, follows these steps. Push to Forgejo
(`origin`), never to GitHub.

```sh
cd ~/projects/homelab
git status                      # must be clean, on main
git switch main
git pull origin main
git switch -c short-branch-name
```

Make the change, then check it locally and commit:

```sh
infra/scripts/ci-checks.sh      # the same checks CI runs
git add -A
git status                      # read what is staged; no secrets, no stray files
git commit -m "area: what changed and why"
git push -u origin short-branch-name
```

Then, in the Forgejo web UI at `https://git.sogode.com/peet/homelab`:

1. Open **Pull requests**, then **New pull request**, with `main` as the base and your
   branch as the compare. Forgejo also offers a link right after the push.
2. Give it a title and a short description: what changed and what the runner will do
   on merge.
3. Wait for `checks / checks (push)` to pass. If the branch is behind `main`, use
   **Update branch** and wait for the checks again.
4. Merge with **Rebase and merge**, and tick **Delete branch after merge**. If the
   change exposes a service or touches an outward-facing path, wait for the owner.

Or do the same from the terminal, through Forgejo's API. Create an access token in
Forgejo (Settings, Applications) with the `write:repository` scope, and put it in
`FORGEJO_TOKEN` without typing it into shell history – from a password prompt, for
example. The helper sends it in a curl config on stdin, so it never appears in a
process list. Run from the repo root, where the CA certificate path resolves:

```sh
read -rs FORGEJO_TOKEN && export FORGEJO_TOKEN     # paste the token, press Enter
API=https://git.sogode.com/api/v1/repos/peet/homelab
fj() {
  curl -sS --fail-with-body --cacert ca/rootca/certs/root.crt -K - "$@" <<EOF
header = "Authorization: token $FORGEJO_TOKEN"
EOF
}

# open the PR from the branch you pushed
BRANCH=$(git branch --show-current)
PR=$(fj -X POST "$API/pulls" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg h "$BRANCH" --arg t "$(git log -1 --format=%s)" \
        '{head:$h, base:"main", title:$t, body:"What changed, and what the runner does on merge."}')" \
  | jq -r .number)
echo "PR #$PR"

# wait for the checks: prints pending, then success or failure
until [ "$(fj "$API/commits/$(git rev-parse HEAD)/status" | jq -r .state)" != pending ]; do sleep 10; done
fj "$API/commits/$(git rev-parse HEAD)/status" | jq -r .state

# only if the branch is behind main: rebase it, push nothing, then wait for the checks again
fj -X POST "$API/pulls/$PR/update?style=rebase"

# merge, and delete the branch afterwards (skip this for a change that waits for the owner)
fj -X POST "$API/pulls/$PR/merge" -H 'Content-Type: application/json' \
  -d '{"Do":"rebase","delete_branch_after_merge":true}'
```

The merge is refused until the checks have passed and the branch is up to date with
`main`, so a failed or stale run stops it rather than landing.

Back in the terminal:

```sh
git switch main
git pull origin main
git branch -d short-branch-name
```

Then confirm the runner applied it: `Actions` in Forgejo shows the apply run, and the
host itself shows the result. `infra/scripts/apply.sh --plan <old> <new>` says what a
merge would run. A change to a host out of the runner's reach is printed in the run
for a person, who runs the named playbook from the checkout, after `git pull`.

## Apply on merge

After the checks and the GitHub publish, `infra/scripts/apply.sh` runs the playbooks
whose sources a merge to `main` changed. It runs with a deploy key on `talos`, set up
by `ansible-playbook deploy-access.yml`. See what a merge would do without applying it:
`infra/scripts/apply.sh --plan <old> <new>`.

It can only reach the services whose roles are safe to run unattended. `pistis`,
`lenora`, `talos`, `lexie`, `ruby` and `jennie` are out of its reach, and a change to
any of them is printed for a person.

A change to `FLEET` runs `enrol.yml`, which re-issues any reachable host whose
certificate names differ, through talos's restricted key on pistis. pistis allows
only the names a person approved there with `ca.yml` – `ca/CLAUDE.md`.

`infra/scripts/tofu-apply.sh` does the same for OpenTofu, when a merge changes
`infra/tofu`. A guest changed by hand is reported as drift, not overwritten. It refuses
any plan that deletes or replaces something, so a person applies those. Its Proxmox
token is `tofu-apply@pve!apply`, with the `TofuApply` role: guest configuration and
power, but no console, guest agent or rights over users.

## Action log

Every automated action writes to the audit trail before it acts and again when it
finishes, using `infra/scripts/action-log`: who, the trigger, the action, the commit,
the targets, the outcome and a link to the run. Query it in Grafana with
`{identifier="homelab-action"}`. A `started` line with no matching `finished` line is
an action that died halfway. If the entry cannot be written, the action does not run.

The `homelab-actions` dashboard shows it, Loki keeps it for a year, and
`infra/scripts/verify-action-log.sh`, run on `talos`, proves the path end to end.

## Kept out of the automation

These change the router, the ONT or Home Assistant OS, so a person runs them, from
the repo. Each is safe to re-run, and each has a `verify.sh` beside it.

| Script | What it installs |
|---|---|
| `wan-watchdog/scripts/deploy.sh` | The dead-WAN watchdog, on the router |
| `wifi-watchdog/scripts/deploy.sh` | The stale Wi-Fi station watchdog, on the router |
| `router-metrics/scripts/deploy.sh` | The read-only metrics dump and forced-command keys, on the router and ONT |
| `appletv-uk/scripts/deploy.sh` | The Apple TV toggle, on the router and in Home Assistant |

`lenora`'s halves of these (the collector and timers) are in `platform.yml`. The
nightly backup job itself is created by `sally/scripts/backups.sh`, since it holds the
PBS token.

## Tasks

Each task ends with a checkpoint before the next begins.

The order from here is 15's review, 16, 17, 20 and 21; task 22 was added
after the table was numbered.

**Where it stands, 12 November 2026** – pick up here:

- **GLPI**, outside the task list: three PRs – the guest (CT 304, OpenTofu),
  the service, and its public side on ruby. `glpi/CLAUDE.md`, "Building it",
  has the order and the person-run steps between them.

- **13 November:** read the first live night, `{identifier="homelab-action"} |=
  "reboot:security"`: ruby and jennie should each reach `succeeded` after their
  reboot; a `failed` names what did not come back.
- **16 November:** review task 15's shadow decisions, then start task 16.
- **Around 18 November:** retire the old ruby report (a `propose` PR, then the owner
  runs `outside.yml` for ruby).
- **Around 9 February 2027:** check the off-site test version
  `lock-test/2026-11-10.txt` has gone, now its lock has run out (`offsite/CLAUDE.md`,
  "The bucket"). On 12 November it was still readable and its deletion refused.

| # | Task | State |
|---|---|---|
| 1 | Repo layout, pinned tools, read-only Ansible reach | Done |
| 2 | Secrets handling a person can take over | Done |
| 3 | Forgejo primary, deploy runner, CI that lints and plans only | Done |
| 4 | PBS on sally, guest backups, a tested restore | Done 11 Nov 2026: sally wakes at night, backs up, mails the result and powers off – `sally/CLAUDE.md` |
| 5 | Import all guests into OpenTofu, with a no-change plan | Done |
| 6 | Fleet roles: hygiene, apt, node-exporter, Alloy | Done |
| 7 | CA and enrolment | Done |
| 8 | Prometheus, Loki, Grafana | Done |
| 9 | DNS stack | Done |
| 10 | Application services: Forgejo, moby, media | Done |
| 11 | lenora, metis, hermes, watchdogs (hermes's role first runs when a lab next has it on) | Done |
| 12 | ruby and jennie, run by a person; router documented; lexie and talos | Done |
| 13 | Apply on merge, retire the old scripts; drop the old `192.168.1.1` nameserver from themis, delphi and pythia | Done |
| 14 | Action log for the audit trail | Done |
| 15 | Runbook engine in shadow mode | Built: shadowing until 16 November 2026, then reviewed before task 16 |
| 16 | Runbooks go live one at a time | |
| 17 | The responder gains authority to act | |
| 18 | Weekly email | Done 11 Nov 2026: on lexie, interpreted by Claude; "needs attention" goes to the runbook engine and the responder (at most three a week) – `estate-report/CLAUDE.md`. A fix the responder proposes becomes a PR from responder-bot's fork, which CI never runs until a person pushes it to origin – `responder/CLAUDE.md` invariant 9. The old ruby report is retired after a week in parallel |
| 19 | Off-site copy of critical backups | Done: restic to Hetzner, first run 10 November 2026, `offsite/CLAUDE.md` |
| 20 | Hands-off soak period: 30 days; each unplanned intervention adds 7; material changes approved by the owner do not count against it | Planned, starts after 16, 17, 18 and 22 |
| 21 | Human takeover drill | |
| 22 | Unattended security updates and reboots for lenora, ruby and jennie | Done 12 Nov 2026: updates were already unattended; `homelab-security-reboot` reboots under the conditions above – `apt/CLAUDE.md`, "Security reboots". One shadow night (ruby and jennie would have rebooted for their kernel, lenora needed none), then live on all three |

## Cost

The transition from AI-custom-managed to standard-autonomous-managed – the work of
9 to 11 November 2026 – cost **$73.96** in one Claude Code session,
as `/cost` reported it at the end:

| | |
|---|---|
| Total cost | $73.96 |
| API time | 3 h 2 min 37 s |
| Wall-clock time | 2 d 22 h 14 min |
| Code changes | 5,350 lines added, 114 removed |
| claude-opus-5-5 | 32.0k input, 1.1M output, 158.8M cache read, 2.6M cache write – $73.84 |
| claude-haiku-5-5 | 189.0k input, 17.1k output, 9 web searches – $0.12 |
| Prompt cache | 713 requests, 98% of input tokens from cache |

It excludes the Claude runs the lab makes itself: the responder and the weekly report.

A service deployed on top of it records its own cost in its `CLAUDE.md`: GLPI,
$22.13 (`glpi/CLAUDE.md`, "Cost").

## Using it

```sh
scripts/verify.sh                                # tools, config and reach; changes nothing

cd ansible                                       # ansible must run from here
ansible fleet -m ansible.builtin.ping
ansible-inventory --graph
ansible-playbook fleet.yml --limit '!hermes' --check --diff   # what would change
ansible-playbook fleet.yml --limit '!hermes'                   # apply
ansible-playbook enrol.yml --limit <host>                      # certificate for a host
ansible-playbook ca.yml --check --diff                         # the CA on pistis; a person runs this
ansible-playbook monitoring.yml --check --diff                 # Prometheus, Loki, Grafana; a person runs this until task 13
ansible-playbook dns.yml --check --diff                        # pythia, then delphi, then themis; a person runs this until task 13
ansible-playbook apps.yml --check --diff                       # Jellyfin, Navidrome, moby, GLPI, Forgejo; a person runs this until task 13
ansible-playbook platform.yml --limit '!hermes' --check --diff # lenora, metis; hermes when a lab has it running
ansible-playbook ci.yml --check --diff                         # lexie's and talos's runners, the responder; always a person
ansible-playbook -i inventory/outside.yml outside.yml --ask-become-pass --check --diff --limit jennie  # then ruby; always a person, and log in first: see outside.yml
../../router/scripts/check.sh                                  # the live router against the settings the lab needs; read-only
```

`fleet.yml` is the baseline on every host, and a run on a healthy fleet changes
nothing. For a new host: add it to `FLEET`, then run `enrol.yml` and `fleet.yml`
limited to it, then `ca.yml` so its name becomes protected. A new host whose
`FLEET` line carries an extra name that is not a lab address – a public name
like `itsm.sogode.com` – needs `ca.yml` *first*: talos's restricted minter
refuses such a name until pistis lists it. hermes is off unless a lab is running, so
leave it out of the run while it is off. sally is not in `FLEET`, by design.

| Path | Holds |
|---|---|
| `versions.env` | The tool versions in use; `verify.sh` fails on a mismatch |
| `tofu/` | OpenTofu configuration; no resources until task 5 |
| `ansible/inventory/fleet.py` | Inventory read from `FLEET` in `ca/scripts/enrol.sh` |
| `ansible/known_hosts` | Pinned ed25519 host keys, by address |
| `secrets/manifest` | Which secrets exist and where each is written locally; names only |
| `scripts/vault.py` | Moves secrets between Bitwarden and the local files |
| `scripts/install-bws.sh` | Installs the pinned `bws`, checksum verified |
| `scripts/ci-checks.sh` | The checks every push must pass; runnable by hand |

## OpenTofu

`tofu/guests.tf` describes every guest but the disposable `9xxx` lab VMs. State is
in the `tofu_state` database on forgejo, encrypted; `scripts/state-db.sh` builds
that database. Always run OpenTofu through `scripts/tofu.sh`, which supplies the
state connection and the Proxmox token.

```sh
scripts/tofu.sh init
scripts/tofu.sh plan
```

The token can only read until task 13, so nothing here can change a guest yet.
Every push runs the plan on `talos` and fails if a guest differs from `guests.tf`.

Each guest's `description` (the Proxmox notes) names the guest and carries the URL of
every web page it serves, admin pages included – add one when a service gains a UI.

To bring in a new guest, read-only, with `<type>` being `container` or `vm`:

```sh
cat > tofu/import.tf <<EOT
import {
  to = proxmox_virtual_environment_<type>.<name>
  id = "lenora/<vmid>"
}
EOT
scripts/tofu.sh plan -generate-config-out=generated.tf
```

Move the block from `generated.tf` into `guests.tf`. Remove lines set to `null`
or `""`, and `units = 0`, `servers = []` and `mac_addresses`. For a container add
`template_file_id` under `operating_system`. Copy the `lifecycle` block from a
guest of the same kind, including `prevent_destroy`. Run `scripts/tofu.sh plan`
until it reads "1 to import, 0 to add, 0 to change", apply, and delete `import.tf`.
Give it a `pool_id` of Infrastructure, Production or Non-Production: that is what
puts it in the nightly backups to sally.

## Adding or changing a VM or container

Everything lands by pull request. OpenTofu makes the guest, Ansible configures it,
and the runners apply both on merge – nothing is created or edited by hand in
Proxmox. Read the "Container defaults" and "Pools, IDs and addresses" sections of
the top-level `CLAUDE.md` first: they hold the conventions this relies on.

### Adding a guest

1. **Reserve the address.** On the router, add a DHCP reservation keyed by MAC,
   below .100 and within the pool's range, before the guest first starts. A person
   does this. Choose the MAC now and set it in `guests.tf`, so the reservation and
   the guest's SLAAC address are known in advance.
2. **Describe it in `tofu/guests.tf`.** Copy the `glpi` container (the first guest
   born in OpenTofu) or, for a VM, a `proxmox_virtual_environment_vm` of similar
   shape. Set `vm_id` and `pool_id` from the pool table, `datastore_id = "ssdpool"`,
   `ip_config` to `dhcp`, the fixed `mac_address`, and keep `prevent_destroy`. The
   `pool_id` is also what puts it in the nightly backup to sally. Include talos's
   restricted deploy key in `user_account.keys`, so apply-on-merge can reach it from
   its first boot.
3. **Add its records.** A and PTR records in `dns/pythia/var/lib/powerdns/zones/`,
   with both serials bumped; `apply.sh` runs `dns.yml` on merge.
4. **Add it to `FLEET`** in `ca/scripts/enrol.sh`. A change to `FLEET` runs
   `enrol.yml` on merge. If the line carries a public name, a person runs `ca.yml`
   first, as above.
5. **Pin its host key** in `ansible/known_hosts`, read through Proxmox as under
   "Host keys" below.
6. **Give it a role.** Add `infra/ansible/roles/<name>/`, sourcing files from
   `<service>/root/`, and list the host in the playbook that matches its trust
   boundary (`apps.yml`, `monitoring.yml`, `dns.yml`, and so on). Check that
   `scripts/apply.sh` runs that playbook for the role's sources; if the host is one
   of those out of its reach, name the person-run playbook in the PR instead.
7. **Monitor it** in the same change: a `node` and an `alloy` target in
   `prometheus/root/etc/prometheus/prometheus.yml`, plus any service job and alert.
8. **Document it** in the service's `CLAUDE.md`, and add a task row or a line under
   "Where it stands" here if it is part of the programme.

Land it as under "Landing a change". Once the PR is merged,
`tofu-apply.sh` creates the guest and `apply.sh` configures it. If the guest exposes
a service or touches an outward-facing path, the PR waits for a person.

### Changing a guest

- **Its Proxmox settings** (cores, memory, disk size, NIC, pool, onboot): edit its
  block in `guests.tf`. Run `scripts/tofu.sh plan` first and expect only the change
  you meant. A merge applies it through `tofu-apply.sh`.
- **A destroy or replace** is refused by `tofu-apply.sh`, so a person runs
  `scripts/tofu.sh apply` for it. Check the plan names what you expect, and that a
  backup of the guest has succeeded first. `prevent_destroy` stays on, and is
  lifted only for that run.
- **Drift:** a guest changed by hand is reported, not overwritten. Either put the
  change in `guests.tf` or revert it in Proxmox.
- **What is on it:** edit the role or the files under `<service>/root/`. Run
  `ansible-playbook <playbook>.yml --limit <host> --check --diff` to see the effect;
  the merge applies it.
- **After a rebuild,** the host key changes: replace its line in
  `ansible/known_hosts`. Keep the MAC, or the router reservation, the certificate
  addresses and any by-MAC DNS exemption stop matching.

### Bringing in a guest that already exists

Use the import steps above, then follow steps 3 to 8 for whatever it lacks.

## Host keys

Ansible refuses any host whose key is not in `ansible/known_hosts`. After a
rebuild, read the new key through Proxmox rather than over the network, so the
network is not what vouches for it, then replace that host's line:

```sh
ssh root@lenora.home pct exec <ctid> -- cat /etc/ssh/ssh_host_ed25519_key.pub
ssh root@lenora.home qm guest exec <vmid> -- cat /etc/ssh/ssh_host_ed25519_key.pub
```

## Repo layout, and why

The repo is split two ways on purpose. Each service has its own top-level
directory – what is on the host (`<service>/root/`, mirroring its filesystem), its
`CLAUDE.md` and its checks. `infra/` holds only what ties them together: the
roles, the playbooks, the inventory, OpenTofu, the apply and CI scripts, and the
secrets manifest. A role sources its files from the service's directory, so a
service's configuration has one home, and the way it reaches a host has another.

Moving the Ansible and OpenTofu into the services' directories was weighed and
rejected on 12 November 2026:

- **Playbooks follow the trust boundary, not the service.** Which playbook a
  role is in says who may apply it – the runner, or a person for pistis,
  lenora, talos, lexie, ruby and jennie – and in what order: Forgejo last,
  because it carries the CI checking the change; Prometheus before Loki before
  Grafana. `scripts/apply.sh` is the one place that says what the runner may
  touch. Spread across the services, that would need a registry built back up
  to drive it.
- **Services and hosts are not one-to-one.** lexie carries the responder, the
  runner, the runbook engine, the weekly report and the code scanning poller;
  moby carries every Docker stack. An OpenTofu guest is a Proxmox object, not a
  service, and several services have no Ansible or OpenTofu at all (the router's).
- **One OpenTofu state is the simplest thing that works.** One provider, one
  plan, one lock, one no-change baseline. A state per service means a loop of
  plans and a `removed` plus `import` for every guest, because `moved` cannot
  cross states.
- **A `common/` would become `infra/` again.** The fleet roles run on every host,
  and the inventory, `ansible.cfg`, `known_hosts`, `versions.env`, the scripts
  and the manifest belong to no single service.
- **Ansible collections are for sharing versioned content between repos.** With
  one repo and one consumer they add a `galaxy.yml`, an `ansible_collections/`
  tree, fully-qualified names and an install step, and nothing to version.
  `roles_path` can list more than one directory if a role should ever live
  beside its service.
- **`dns/ansible/`** – zone data with its own `ansible.cfg` and inventory, kept
  from before this programme – shows what per-service Ansible costs: a second
  config and inventory to keep in step.

Revisit if the estate gains tenants with separate owners or trust levels. Then
the tenant, not the service, becomes the boundary: its own playbooks, inventory,
OpenTofu state, runner reach and secrets project – which is a split by tenant,
not by service.

## Where the code lives

Forgejo's private `peet/homelab` is the primary. Every push runs
`.forgejo/workflows/checks.yml` on `talos`, and a passing run on `main` publishes
to GitHub, which is public; ruby and jennie pull from there. A finding from the
secret scan stops publication. If it is a false positive, add it to
`.gitleaksignore`; if it is real, rotate the secret and rewrite the commit.
`talos/CLAUDE.md` covers the runner.

## Secrets

Bitwarden Secrets Manager holds every secret. `~/projects/homelab-private` and
the gitignored files named in `secrets/manifest` are a cache of it, in the
layout the deploy scripts read, so they can be deleted and rebuilt.

| Project | Holds | Who gets a token |
|---|---|---|
| `homelab` | Service credentials | A person's laptop; later the deploy runner |
| `homelab-restricted` | CA, WireGuard and Orange credentials | A person's laptop only, never automation |

The root CA key is in the owner's Bitwarden vault and nowhere else;
`ca/README.md` says how to use it. No agent or automated account other than the
deploy runner ever holds a token.

### Taking over

You need a Bitwarden account with access to the organisation. In Secrets Manager
create a machine account with access to both projects and copy its access token.

```sh
scripts/install-bws.sh
export BWS_ACCESS_TOKEN=...          # from a password prompt or clipboard, not typed into history
                                     # or, on a Mac, once into the keychain – vault.py's docstring
scripts/vault.py pull                # rebuild every local file, mode 600
scripts/vault.py verify              # names only; exits non-zero on any difference
```

### Rules

- A name must be unique within its project: Bitwarden allows duplicates, and
  `vault.py` stops rather than guess.
- A value can be at most 25,000 characters, so text only. Binary files such as
  router backups do not belong here.
- `pull` rewrites env files without their comments. Keep explanations in the
  repo, not beside the values.
- Fetching needs the WAN. Running services hold their own copies, so an outage
  only stops a deploy that has to fetch a new value.

### Adding or changing a secret

Add a line to `secrets/manifest` if it is new, put the value in the local file,
then run `scripts/vault.py import`. It changes only what differs and reads every
value back.

### Rotating a secret

Change it at its origin, update the local file, run `scripts/vault.py import`,
then run what consumes it. Rows marked *person* are outward-facing or need
access the automation does not have.

| Secrets | Origin | Then run |
|---|---|---|
| `dns/*` | Generate new; `DNSDIST_API_KEY_HASHED` is derived from `DNSDIST_API_KEY` | `infra/ansible/dns.yml` |
| `hermes/API_KEY` | mailcow admin | `hermes/scripts/deploy.sh` |
| `forgejo/SMTP_PASSWD` | Mailbox on ruby – *person* | `infra/ansible/apps.yml` |
| `forgejo/RUNNER_LEXIE_SECRET` | Generate 40 hex characters | `infra/ansible/apps.yml`, then `infra/ansible/ci.yml` |
| `grafana-admin/GRAFANA_PASSWORD` | Grafana | `infra/ansible/monitoring.yml` |
| `grafana/viewer-token` | Grafana service account | Nothing; read at use |
| `grafana/HA_WEBHOOK_ID`, `responder/HA_WEBHOOK_ID` | Home Assistant automation | `infra/ansible/monitoring.yml`, `infra/ansible/ci.yml` |
| `grafana/HEALTHCHECKS_PING_URL` | Healthchecks.io – *person* | `infra/ansible/monitoring.yml` |
| `responder/RESPONDER_TOKEN` | Generate new | `infra/ansible/ci.yml` |
| `n8n/SMTP_PASSWD`, `n8n-sogode/SMTP_PASSWD` | Mailbox on ruby – *person* | `infra/ansible/apps.yml` |
| `glpi/MAIL_PASSWORD` | Mailbox `helpdesk@itsm.sogode.com` on ruby – *person* | `infra/ansible/deploy-access.yml`, then a merge touching `glpi/` or `apps.yml` |
| `glpi/ADMIN_PASSWORD` | Generate new; used only when `peet` is created in GLPI | Nothing afterwards: GLPI holds it (`glpi/CLAUDE.md` invariant 2) |
| `jobsearch/*` | n8n, Forgejo or Anthropic console, or the mailbox on ruby – *person* | `infra/ansible/ci.yml` |
| `esp32/kitchen-api-key` | ESPHome config | Reflash the device |
| `ca/*` | `ca/README.md` – *person* | `infra/ansible/ca.yml` |
| `wireguard/*` | `wireguard/README.md` – *person* | Install on the router, ruby and jennie |
| `router/ORANGE_*` | Orange – *person* | `router/ORANGE.md` |
