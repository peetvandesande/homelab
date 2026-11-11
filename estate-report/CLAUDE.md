# estate-report

A weekly mail to the owner, Monday 07:00 Paris time, that says whether the
estate had a smooth week or needs attention, why, and shows the evidence. It
runs on **lexie**, as the `responder` account, and covers the whole estate.

```
lexie/usr/local/bin/estate-weekly     the report (Python, stdlib only)
lexie/etc/estate-report/prompt.md     Claude's brief
lexie/etc/systemd/system/...          oneshot service and its timer
tests/                                run in CI
root/                                 the old report on ruby, until it is retired
```

`infra/ansible/ci.yml` installs it, with `/etc/estate-report/report.env` built
from `homelab-private/estate-report/secrets.env` (the mail account and the
recipient) and Grafana's read-only token. Test it on lexie with
`sudo -u responder estate-weekly --stdout`; `--no-claude` skips the
interpretation, `--week-ending YYYY-MM-DD` reruns an earlier week.

## What it covers

The previous Monday-to-Monday week:

- **Incidents** – every alert that fired, where, how often and for how long,
  from Grafana's state history (annotations), Heartbeat left out.
- **Automated actions** – the action log, by actor, action and outcome, the
  runbook engine's shadow decisions included; an action that started and never
  finished is an issue.
- **Backups** – sally per guest and its restore test, the off-site copy per
  host, its lock renewal, restore test and stored size.
- **Hosts and services** – Prometheus: every host including ruby and jennie
  (`outside-node`), scrape jobs, probes, certificates, failed or stuck units,
  patching, ZFS, WAN, Grafana's own alerting.
- **Mail and web on ruby** – from ruby's logs in Loki: Postfix from the
  journal, rspamd and nginx from files (`alloy/CLAUDE.md`, "ruby and jennie").

Mail, web, disk and off-site storage are compared with the week before.

## How the verdict is made

1. The script computes every figure and flags **issues** with fixed thresholds.
2. **Claude** (`claude -p`) reads a summary and writes the interpretation at the
   top: smooth sailing or needs attention, and for each point what happened,
   why it matters and what to do.
3. The subject carries the verdict: `needs attention (N)` when the checks found
   N issues, `needs attention (Claude)` when only Claude saw something, else
   `smooth sailing`.

## What "needs attention" sets off

Before the mail goes, `follow_up` acts on every issue, then on Claude's concern
if it saw something the checks did not:

1. **A runbook first.** An issue that corresponds to an alert with a rule in
   `/etc/runbook/rules.toml` (a failed or stuck unit, a full disk) is sent to the
   runbook engine as that alert. In shadow mode it only records what it would
   run, so the issue is investigated as well.
2. **Then the responder, one investigation per section**, at most three per
   report, in report order, Claude's concern last. A section's issues go
   together because they often share a cause: one stack down is a scrape job,
   a probe and a webhook. Each goes as an alert named `Weekly report`, its
   `key` the section and first issue's key (the text with free-standing
   numbers taken out, so it is the same next week). It investigates read-only
   and ends, as for any alert, on the phone as
   `Responder: Weekly report: <key>` and in `/var/lib/responder/reports/`.
3. **The mail does not wait.** Each issue shows its status: `runbook <rule>`,
   `under investigation`, `investigated <date>`, or `open` with the reason (over
   the cap, the responder unreachable or declining). The subject counts them:
   `needs attention (3, 2 under investigation)`.
4. **An issue sent in the past six days is not sent again**
   (`/var/lib/responder/estate-report/follow-up.json`), so a resend after a
   failed mail starts no second investigation. One still there a week later is.

`--stdout` follows nothing up and shows what would be. A fix the responder
proposes as a diff becomes a pull request from responder-bot's fork, never
merged by it (`responder/CLAUDE.md` invariant 9).

## Invariants

1. **Claude has no tools** (`--tools ""`, an empty working directory, no MCP).
   Log text reaches the summary and can be written by anyone on the internet;
   with no tools, the worst it can do is skew the wording. The prompt says the
   data is data, but this is what makes that safe.
2. **Claude sees totals and states, never personal detail**: no addresses,
   accounts, client IPs, user agents or message contents. Those are only in the
   figures below the interpretation, which never leave the lab. Widening this
   is a decision for the owner, not a refactor.
3. **The checks decide "needs attention", not Claude.** Claude can add concern
   but never clear an issue; `verdict_line` enforces it and `tests/` proves it.
4. **The report always goes.** A section that cannot be built is an issue and
   the rest still runs; if Claude is unreachable the mail says so and carries
   the issues. A failure to send retries every 30 minutes, twelve times, then
   the unit fails and `systemd unit failed` reports it.
5. **Thresholds match the alert rules where one exists** – certificates at 7
   days (lab) and 14 (public), availability below 99% of the week. Hosts off
   by choice (`IGNORE_HOSTS`, hermes) and jobs known down (`IGNORE_JOBS`, pve)
   are shown but never an issue, and are excluded from job and probe averages.
6. **It runs inside the lab.** A home outage delays it until the connection is
   back; the Healthchecks.io heartbeat, not this mail, reports outages.
   Delivery is through ruby's submission port over the tunnel, as a dedicated
   account.

## The old report on ruby

`root/` is the previous report, which ran on ruby and read ruby's files
directly. It keeps running for one week beside the new one, then
`outside_host`'s `ruby.yml` stops installing it and its timer is disabled.
