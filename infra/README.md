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

## Apply on merge

After the checks and the GitHub publish, `infra/scripts/apply.sh` runs the playbooks
whose sources a merge to `main` changed. It runs with a deploy key on `talos`, set up
by `ansible-playbook deploy-access.yml`. See what a merge would do without applying it:
`infra/scripts/apply.sh --plan <old> <new>`.

It can only reach the services whose roles are safe to run unattended. `pistis`,
`lenora`, `talos`, `lexie`, `ruby` and `jennie` are out of its reach, and a change to
any of them is printed for a person.

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

The order from here is 18, 16, 17, 22, 20 and 21; task 22 was added after the table was
numbered.

| # | Task | State |
|---|---|---|
| 1 | Repo layout, pinned tools, read-only Ansible reach | Done |
| 2 | Secrets handling a person can take over | Done |
| 3 | Forgejo primary, deploy runner, CI that lints and plans only | Done |
| 4 | PBS on sally, guest backups, a tested restore | |
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
| 18 | Weekly email | |
| 19 | Off-site copy of critical backups | Done: restic to Hetzner, first run 10 November 2026, `offsite/CLAUDE.md` |
| 20 | Hands-off soak period: 30 days; each unplanned intervention adds 7; material changes approved by the owner do not count against it | Planned, starts after 16, 17, 18 and 22 |
| 21 | Human takeover drill | |
| 22 | Unattended security updates and reboots for lenora, ruby and jennie | |

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
ansible-playbook apps.yml --check --diff                       # Jellyfin, Navidrome, moby, Forgejo; a person runs this until task 13
ansible-playbook platform.yml --limit '!hermes' --check --diff # lenora, metis; hermes when a lab has it running
ansible-playbook ci.yml --check --diff                         # lexie's and talos's runners, the responder; always a person
ansible-playbook -i inventory/outside.yml outside.yml --ask-become-pass --check --diff --limit jennie  # then ruby; always a person, and log in first: see outside.yml
../../router/scripts/check.sh                                  # the live router against the settings the lab needs; read-only
```

`fleet.yml` is the baseline on every host, and a run on a healthy fleet changes
nothing. For a new host: add it to `FLEET`, then run `enrol.yml` and `fleet.yml`
limited to it, then `ca.yml` so its name becomes protected. hermes is off unless a lab is running, so
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
Remember `GUESTS` in `sally/scripts/backups.sh`.

## Host keys

Ansible refuses any host whose key is not in `ansible/known_hosts`. After a
rebuild, read the new key through Proxmox rather than over the network, so the
network is not what vouches for it, then replace that host's line:

```sh
ssh root@lenora.home pct exec <ctid> -- cat /etc/ssh/ssh_host_ed25519_key.pub
ssh root@lenora.home qm guest exec <vmid> -- cat /etc/ssh/ssh_host_ed25519_key.pub
```

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
| `jobsearch/*` | n8n, Forgejo or Anthropic console, or the mailbox on ruby – *person* | `infra/ansible/ci.yml` |
| `esp32/kitchen-api-key` | ESPHome config | Reflash the device |
| `ca/*` | `ca/README.md` – *person* | `infra/ansible/ca.yml` |
| `wireguard/*` | `wireguard/README.md` – *person* | Install on the router, ruby and jennie |
| `router/ORANGE_*` | Orange – *person* | `router/ORANGE.md` |
