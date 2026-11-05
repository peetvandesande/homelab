# Forgejo runner

The lab's one Forgejo Actions runner. Runs on **lexie** (CT 100,
192.168.8.24) as its own `forgejo-runner` user: forgejo-runner v13.2.0,
`/usr/local/bin`, systemd unit `forgejo-runner.service`, **host jobs** under
the label **`lexie`**, one at a time. Built 5 November 2026 so the job search
repos deploy on push (`sogode-jobsearch/ci/deploy.sh`); first built on moby
the same day and moved here, so moby stays a Docker host only.

`root/` mirrors lexie's filesystem for this service. `scripts/deploy.sh`
installs it.

## Deploy order

1. `forgejo/scripts/deploy.sh` – registers the runner (`--scope peet`, label
   `lexie`) with the shared secret.
2. `scripts/deploy.sh` – this: account, key, binary, config, secrets. It also
   stops the old runner on moby, so two daemons never poll with one token.
3. `moby/scripts/deploy.sh` – authorises this runner's key for
   `jobsearch-schema` (and removes what is left of the old runner there).
   Until then the job search deploy fails at its schema step.

## Invariants

1. **A job can do three things, and that list is the security boundary.**
   Jobs run as `forgejo-runner` directly on lexie, so whatever that account
   holds, every workflow in peet's repositories holds:
   - its own SSH key, which **moby accepts from lexie only and forces to
     `/usr/local/sbin/jobsearch-schema`** (`moby/CLAUDE.md`): load SQL from
     stdin into one job search database. No shell, no pty, no forwarding.
   - `/etc/forgejo-runner/jobsearch.env`: both n8n API keys and the Forgejo
     read token.
   - outbound HTTPS, like any account.
   It has no group beyond its own, no sudo, and **it is not `peet`**: peet's
   key is accepted across the lab, so a runner under that account would hand
   every job the whole lab. Never run it as peet, and never add its key
   anywhere without a forced command.
2. **Registered for peet's repositories only** (`--scope peet`), never
   instance-wide: a workflow in anyone else's repository just waits.
3. **The connection is in `config.yml`, not a `.runner` file**
   (`create-runner-file` is deprecated in v13). The token is the shared
   secret `RUNNER_LEXIE_SECRET` from `homelab-private/forgejo/secrets.env`,
   root-only in `/etc/forgejo-runner/token` and handed to the service by
   `LoadCredential`; `deploy.sh` fills the UUID in `config.yml`, derived from
   the secret the way Forgejo derives it (first 16 characters as bytes).
   Rotate: change the secret, then steps 1 and 2 above.
4. **Jobs' secrets live here, not in Forgejo.** `deploy.sh` writes
   `jobsearch.env` (root:forgejo-runner 0640) from
   `homelab-private/jobsearch/secrets.env` on every run; a rotated n8n key or
   Forgejo token needs a re-run.
5. **IPv4 to moby, host key seeded.** The runner's `~/.ssh/config` names moby
   `moby` (192.168.8.27, user `jobsearch-ci`, `AddressFamily inet`), because
   the key is accepted from 192.168.8.24 only; `deploy.sh` scans moby's host
   key into `known_hosts` instead of trusting it on first use. Rerun after
   rebuilding moby.

## Checking it

`journalctl -u forgejo-runner` on lexie shows the connection ("declared
successfully") and each task. Runs and their logs are under each
repository's Actions tab.
