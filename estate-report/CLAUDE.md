# estate-report

A weekly mail, Monday 07:00 Paris time, that says whether the estate is
healthy and shows the evidence. It runs on **ruby** and replaces logwatch,
which is still installed there but has had nothing to read since Debian 13
dropped rsyslog: Postfix logs only to the journal, and logwatch reads files.

```
root/usr/local/bin/estate-report     the report (Python, stdlib only)
root/etc/systemd/system/...          oneshot service and its timer
root/etc/default/estate-report       template; REPORT_TO filled on install
install.sh                           sudo ~/homelab/estate-report/install.sh <recipient>
```

It covers the previous Monday-to-Monday week:

- **Mail on ruby** – messages received, submitted, forwarded and rejected;
  recipients per domain, sorted by count, for mailbox delivery, sending,
  forwarding and rejection; rspamd's verdicts; senders by account. Postfix
  comes from the journal (`SYSLOG_FACILITY=2`), rspamd from
  `/var/log/rspamd/rspamd.log*` and the journal.
- **ruby** – key units, failed units, mail queue, disk, pending security
  upgrades, reboot required, Postfix's certificate. ruby is not in the lab's
  Prometheus, so this is read on the host.
- **The lab** – from `prometheus.home` over wg1: per-host availability,
  reboots and disk, every scrape job, LAN and outside probes, certificate
  expiry, failed or stuck units, patching, ZFS pools, ONT and router, Grafana
  alerting.

Test it with `estate-report --stdout`; `--week-ending YYYY-MM-DD` reruns an
earlier week, and `--postfix-log FILE` reads syslog-format lines instead of the
journal.

## Invariants

1. **It runs on ruby, outside the home connection.** A home outage then shows
   up as the lab section failing rather than as no mail at all, and ruby's
   own Postfix sends it, so delivery does not depend on the lab.
2. **A check that cannot run is an issue.** Every section is built
   independently; an exception becomes a line in ISSUES and the rest of the
   report still goes. An empty Postfix log is an issue, not a quiet week.
3. **Week-long figures are evaluated at the end of the week; "State at report
   time" and certificates are evaluated when it runs.** Series must still
   exist at the end of the week to count, so instances renamed mid-week (as in
   the IPv6 rollout) drop out instead of showing as down.
4. **Thresholds match the alert rules where one exists**: the lab certificate
   check skips the instance `Lab certificate expiring` skips. Below 99% weekly
   availability is an issue – about 100 minutes.
