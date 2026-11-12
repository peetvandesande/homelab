# Responder

An AI agent that investigates alerts. Runs on **lexie** (CT 100, 192.168.8.24)
as its own `responder` user; Grafana's webhook calls it, Claude (`claude -p`)
looks into the alert **read-only**, and the finding goes to the phone through
the existing Home Assistant webhook as a warning titled `Responder: <alert>`.

`root/` mirrors lexie's filesystem. `infra/ansible/ci.yml` pushes it,
`scripts/hosts.sh` creates the matching unprivileged account on the fleet, and
`scripts/verify.sh` checks it. `homelab-private/responder/secrets.env` holds
`HA_WEBHOOK_ID` and the generated `RESPONDER_TOKEN`; `infra/ansible/monitoring.yml`
reads the token from there.

## First-time setup

1. `infra/ansible/ci.yml`, then log Claude in as the account – it cannot be
   scripted: `ssh peet@lexie`, `sudo -iu responder`, `claude auth login`.
2. `scripts/hosts.sh` to let it SSH to the fleet (journal and adm groups, key
   accepted from lexie only).
3. `infra/ansible/monitoring.yml` to add the `responder` contact point. Do this
   last: it rewrites the live notification policy.
4. `scripts/verify.sh`.

## Invariants

1. **Read-only, enforced by the account, not the prompt.** The prompt says
   don't change anything; what actually stops it is that `responder` on every
   host has no sudo, no password and only the `systemd-journal` and `adm`
   groups. Claude's tool allowlist (`Write`/`Edit` denied, `Bash` limited to
   `ssh`, `curl`, `dig`) is a second layer. Widening remediation means adding a
   narrow, named sudo rule per action on the target host – never a broader key.
2. **Alert text is untrusted.** Log lines reach labels and annotations, so the
   alert is passed as fenced data and the prompt says so. This is why invariant
   1 matters more than the prompt.
3. **`allowed-alerts` decides what it acts on**, by rule title, and ships
   narrow: failed and stuck units, disk and memory, and GitHub code scanning
   findings (`github-alerts/`), whose fix is always a pull request. Grafana sends it every
   alert; the filter is here so widening is one file and one deploy. Leave the
   router, DNS stack, CA and WAN alerts off until you have read a few reports –
   those are the places where a wrong suggestion costs access to fix.
   `Weekly report` is not a Grafana rule: the weekly estate report sends one
   per issue it needs attention for, named by a `key` label, which the push
   title and report file carry (`estate-report/CLAUDE.md`).
4. **One investigation at a time, one per alert per hour.** A single worker, a
   queue of four (overflow is dropped and logged), and a cooldown keyed on the
   alert fingerprint, so a flapping rule cannot run it in a loop. Each run is
   capped at 25 turns, $1 and ten minutes.
5. **TLS off the lab CA on :9095, plus a bearer token.** Lexie is enrolled
   (`ca/scripts/enrol.sh`), so the receiver serves the host certificate; the
   `responder` user is in `tlscert` to read the key and
   `post-renew.d/30-responder` restarts the service on renewal. Grafana
   reaches it by IP, verified against the IP SAN, like Home Assistant.
6. **It rides the same path as the alerts.** Grafana, lexie and HA must all be
   up, so it cannot report a home outage; the heartbeat still owns that.
7. **SSH is IPv4-only, with seeded host keys.** Each host's `authorized_keys`
   entry carries `from="192.168.8.24"`, so the responder's `~/.ssh/config`
   pins `AddressFamily inet` – a name that resolved to a ULA would otherwise
   be refused. Lexie's own entry also allows `127.0.0.1`, because its own name
   resolves to loopback. Host keys are scanned into `known_hosts` by
   `hosts.sh` (non-interactive ssh cannot prompt); rerun it after rebuilding a
   host. All of this was found by the first live report, which said it could
   not reach lexie.

8. **The report ends in a verdict, and the verdict picks the push.** Home Assistant's
   automation knows only firing and resolved, so: `action-needed` is a
   warning titled 🔧 (a *warning*, not critical, until the verdicts have proved
   reliable – a wrong one at critical wakes you), `unsure` a plain warning,
   and `no-action` is sent as *resolved*, which that automation delivers
   silently. A missing verdict counts as `unsure`. A run that fails or times
   out pushes "could not investigate" rather than staying silent. The push
   cannot link to the report – the tap-through URL is fixed in the HA
   automation – so the message ends with the report's file name; read it with
   `scripts/reports.sh latest`.

9. **A proposed fix becomes a pull request, never a merge.** An
   `action-needed` report may end in a diff. The responder leaves it in
   `/var/spool/responder-pr/`, and `responder-pr` – its own account, started by
   a path unit – applies it to a fresh branch of main, pushes that to
   **responder-bot**'s fork and opens a pull request from there, then pushes
   the link to the phone. Claude never holds the Forgejo token: it is in
   `/etc/responder-pr/`, unreadable to `responder`. At most three a week, ten
   files, 64 KiB; workflows, `infra/scripts/`, `.git*` files, secrets, keys,
   symlinks and submodules are refused. That list is a backstop, not the gate –
   CI's tests import the code they test, so nearly any file runs on talos once
   checked.

   **The gate is the fork.** `checks.yml` runs on push, and the runner takes
   peet's repositories only, so a branch on the fork runs nowhere. Read the
   diff first; to check it, push it to origin
   (`git fetch <fork> <branch> && git push origin FETCH_HEAD:refs/heads/<branch>`),
   which is what runs it on talos. Until task 22's required review exists,
   merging stays by hand. Claude reads the repo from a shallow copy of the
   public GitHub mirror in `/var/lib/responder/repo`, refreshed before each run.

Reports are kept in `/var/lib/responder/reports/` on lexie, one file per run.
