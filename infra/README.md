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
| Restarts | Staggered service restarts by runbook, DNS hosts one at a time; lenora reboots stay with a person |
| Order | Full migration to OpenTofu and Ansible first, then autonomy |
| Backups | Proxmox Backup Server on a dedicated Dell, out of the agent's reach; ruby and jennie rely on OVH's daily snapshots |
| Weekly email | A new section of `estate-report`, sent only to the owner |

**Never without a person:** exposing secrets or services, and outward-facing
actions. The limits are enforced by what each account can do, not by what a
prompt says, because alert text carries untrusted log lines.

The agent merging its own work needs a condition, because `main` is mirrored to
a public repository: a merged secret is published. The required checks must
include secret scanning, and any change that exposes a service or touches an
outward-facing path must wait for a person.

The router and Home Assistant OS cannot be fully managed by Ansible, so they
stay documented or specially handled. ruby and jennie get Ansible roles that a
person runs.

## Tasks

Each task ends with a checkpoint before the next begins.

| # | Task | State |
|---|---|---|
| 1 | Repo layout, pinned tools, read-only Ansible reach | Done |
| 2 | Secrets handling a person can take over | |
| 3 | Forgejo primary, deploy runner, CI that lints and plans only | |
| 4 | PBS on the Dell, guest backups, a tested restore | |
| 5 | Import all guests into OpenTofu, with a no-change plan | |
| 6 | Fleet roles: hygiene, apt, node-exporter, Alloy | |
| 7 | CA and enrolment | |
| 8 | Prometheus, Loki, Grafana | |
| 9 | DNS stack | |
| 10 | Application services: Forgejo, moby, media | |
| 11 | lenora, metis, hermes, watchdogs | |
| 12 | ruby and jennie, run by a person; router documented | |
| 13 | Apply on merge, retire the old scripts | |
| 14 | Action log for the audit trail | |
| 15 | Runbook engine in shadow mode | |
| 16 | Runbooks go live one at a time | |
| 17 | The responder gains authority to act | |
| 18 | Weekly email | |
| 19 | Off-site copy of critical backups | |
| 20 | Hands-off soak period | |
| 21 | Human takeover drill | |

## Using it

```sh
scripts/verify.sh                                # tools, config and reach; changes nothing

cd ansible                                       # ansible must run from here
ansible fleet -m ansible.builtin.ping
ansible-inventory --graph
```

| Path | Holds |
|---|---|
| `versions.env` | The tool versions in use; `verify.sh` fails on a mismatch |
| `tofu/` | OpenTofu configuration; no resources until task 5 |
| `ansible/inventory/fleet.py` | Inventory read from `FLEET` in `ca/scripts/enrol.sh` |
| `ansible/known_hosts` | Pinned ed25519 host keys, by address |

## Host keys

Ansible refuses any host whose key is not in `ansible/known_hosts`. After a
rebuild, read the new key through Proxmox rather than over the network, so the
network is not what vouches for it, then replace that host's line:

```sh
ssh root@lenora.home pct exec <ctid> -- cat /etc/ssh/ssh_host_ed25519_key.pub
ssh root@lenora.home qm guest exec <vmid> -- cat /etc/ssh/ssh_host_ed25519_key.pub
```
