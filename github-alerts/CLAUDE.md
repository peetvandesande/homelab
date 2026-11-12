# GitHub code scanning alerts

GitHub scans the public mirror with CodeQL on every push to `main` and on
Tuesdays at 20:17 – its default setup, configured on GitHub, not here. This
brings what it finds into the lab's own alerting, so a finding reaches the
phone without anyone opening GitHub.

## How it works

`github-alerts` runs on lexie every 15 minutes (`github-alerts.timer`) and reads
the open code scanning alerts through GitHub's API. It writes
`github_alerts.prom` into node-exporter's textfile collector:

| Metric | Means |
|---|---|
| `github_code_scanning_alert{number,rule,severity,tool,path,line,summary,url}` | one series per open alert |
| `github_code_scanning_alerts_open{severity}` | how many, by severity, zeros included |
| `github_code_scanning_poll_success_timestamp_seconds` | when the alerts were last read |

Grafana's `github` group (`grafana/.../alerting/github.yaml`) fires
**"GitHub code scanning alert"** once per open alert, naming the rule and the
file and line, and **"GitHub code scanning is not being read"** after two hours
without a successful poll – a 401 or 403 in `journalctl -u github-alerts` means
the token has expired or lost access. The first is in the responder's
`allowed-alerts`, so it investigates and may propose a fix as a pull request,
opened only (`responder/CLAUDE.md`).

A finding usually appears within 15 minutes of GitHub's scan finishing; the
scan itself starts once a push to `main` is published from Forgejo. Pull
requests happen on Forgejo, so GitHub never scans them.

A failed poll leaves the last good file in place: GitHub or the network being
down logs and exits cleanly, so `systemd unit failed` stays quiet and the
staleness rule speaks for a lasting failure instead. A wrong token fails the
unit.

## Dealing with an alert

Fix it in this repo by pull request; the alert closes on GitHub at the next scan
of `main`, and here at the next poll. A false positive is dismissed on GitHub,
with its reason – that is the record of why.

## Working on this

`root/` mirrors what is installed on lexie, by the `github_alerts` role in
`infra/ansible/ci.yml` – run by a person, since lexie is outside the runner's
reach. `tests/` runs in CI.

The token is `github-alerts/GITHUB_TOKEN` in Bitwarden: fine-grained, for
`peetvandesande/homelab` only, with read access to code scanning alerts and
nothing else. It sits in `/etc/github-alerts/github-alerts.env`, root only. When
it expires, make a new one with the same scope, put it in
`homelab-private/github-alerts/secrets.env`, `vault.py import`, and rerun
`ci.yml --limit lexie`.
