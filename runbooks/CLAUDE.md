# Runbooks

Exact-match rules that decide what an alert runs, with no LLM involved, so they work
with the internet down. The engine runs on **lexie** as its own `runbook` account and
listens on `:9096`. Grafana sends it a copy of every alert. `root/` mirrors lexie's
filesystem and `infra/ansible/ci.yml` deploys it. `scripts/verify.sh` checks it.

## Invariants

1. **Shadow mode cannot change anything, by account as well as by code.** `runbook`
   has no SSH key and no sudo, and the engine refuses to start on any rule whose mode
   is not `shadow`. Going live (task 16) adds one narrow, named permission per runbook.
2. **Alert text is untrusted.** Log lines reach labels, so a label is only ever
   compared against `rules.toml`. It never reaches a shell, and anything that did not
   match is cleaned before being written down.
3. **A host or unit not listed is refused.** It is recorded as `refused`, which shows
   what a rule's allowlist is missing.
4. **Each rule's `alert` is the exact Grafana title.** Renaming an alert silently
   disconnects its rule.
5. **One record per alert per hour**, keyed on the rule, target and fingerprint, one at
   a time, from a queue of 16.

Results are in the action log, on the `homelab-actions` dashboard: look for `shadow`
and `refused`. The token is `RUNBOOK_TOKEN` in `responder/secrets.env`, which is where
the `grafana` role already reads the responder's.
