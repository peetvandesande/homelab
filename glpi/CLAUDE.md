# glpi

GLPI, the lab's ITSM suite – assets, tickets, changes and problems – on its own
LXC, **CT 304, `glpi.home`, 192.168.8.63**, in the `Production` pool. It knows
itself by one name, **`itsm.sogode.com`**, which inside the lab resolves to glpi
by split-horizon (`dns/ansible/group_vars/all.yml`, "itsm.sogode.com"). Its mail
is the mailbox `helpdesk@itsm.sogode.com` on ruby.

| | |
|---|---|
| Guest | `infra/tofu/guests.tf`, `glpi` – created by OpenTofu, MAC `BC:24:11:47:4C:50` |
| Role | `infra/ansible/roles/glpi`, in `apps.yml`, applied on merge |
| Files | `root/` mirrors the host |
| Version | `glpi_version` and `glpi_sha256` in the role's `vars/main.yml` |
| Secrets | `homelab-private/glpi/secrets.env`: `ADMIN_PASSWORD`, `MAIL_PASSWORD` |
| Backups | sally nightly (the whole guest); off-site by `offsite.yml` |

```
/opt/glpi/glpi-<version>/        each release, root-owned; current -> the one in use
/etc/glpi/                       config_db.php, glpicrypt.key, local_define.php
/etc/glpi-homelab/               the passwords the role generates; applied-settings hashes
/var/lib/glpi/files/             documents, sessions, cache (GLPI_VAR_DIR)
/var/lib/glpi/marketplace/       plugins (GLPI_MARKETPLACE_DIR)
/var/log/glpi/                   GLPI's own logs
```

nginx on :443 with the lab certificate (which carries `itsm.sogode.com`),
php8.4-fpm, MariaDB on its socket, and `glpi-cron.timer` running GLPI's
automatic actions every minute.

## Working on this

**Upgrading** is a PR that bumps `glpi_version` and `glpi_sha256` (the release's
`.tgz` digest on GitHub). The role unpacks the new release beside the old one,
puts GLPI in maintenance mode, switches `/opt/glpi/current`, runs `db:update`
and leaves maintenance mode. The previous release stays in `/opt/glpi`: a
rollback is the link back plus a restore of the database from sally, since
`db:update` does not run backwards. Read the release notes for a major version
first; plugins lag behind them.

**Plugins** come from the Marketplace in GLPI's UI (Setup > Plugins) and live in
`/var/lib/glpi/marketplace`, outside the code, so an upgrade keeps them. A
plugin that is not on the Marketplace is unpacked there by hand. They are state,
like tickets, and are backed up with them.

**Configuration through the UI is fine** for everything the role does not set:
it owns the settings in `glpi_settings` (URL, API, notification addresses,
SMTP) and the one mail collector in `glpi_collector`, and leaves the rest of
GLPI alone. A change made in the UI to one of those is overwritten only when the
role's own values change – see invariant 4.

**Console:** `runuser -u www-data -- php /opt/glpi/current/bin/console` on glpi.
Never as root: files it creates become unwritable to php-fpm.

## Invariants

1. **The web installer is deleted from every release.** `install/install.php`
   would let anyone who reaches it reinstall over the database. The role removes
   it after unpacking; a hand-unpacked release would bring it back.

2. **GLPI's default accounts are disabled**, not deleted: `glpi`, `tech`,
   `normal` and `post-only`, whose passwords everyone knows. The owner's account
   is `peet`, Super-Admin, created with `ADMIN_PASSWORD` and the owner's to change
   from then on – the role never resets it, so Bitwarden can fall behind it.

3. **The REST API answers on loopback only, for the role.** It is enabled, with
   password login, because mail collectors have no console command: the role
   writes the collector through it, as `homelab-automation`, a Super-Admin whose
   password the role generates and resets on every run. Two locks keep it local:
   nginx refuses `/apirest.php` on :443 however it is spelt, and GLPI's only API
   client is "full access from localhost". Do not add an API client or open the
   path without replacing that account.

4. **The role's settings are applied by hash, not compared.** `config:set`
   always writes, and the SMTP and IMAP passwords are stored encrypted, so they
   cannot be read back to compare. The role keeps a hash of what it last
   applied in `/etc/glpi-homelab/{settings,collector}.sha256` and applies again
   only when its values change. Delete a hash file to force a reapply.

5. **`/etc/glpi/glpicrypt.key` is the key to every stored password.** Losing it
   loses the SMTP and mail collector passwords, and any LDAP or OAuth secrets
   added later. It is in both backups with the database; restore them together.

6. **Every automatic action runs from the timer** (`glpi_crontasks.mode = 2`).
   GLPI's default runs some on page views, which would leave mail uncollected
   while nobody is logged in. `cron.php` refuses root, so the unit runs as
   `www-data`; a failing run marks it failed, which the `systemd-unit-failed`
   alert sees.

7. **Mail goes through ruby over the tunnel.** Submission on
   `mail.peetvandesande.com:587` and IMAPS on :993, both of which resolve inside
   the lab to ruby's wg0 address, the only place ruby serves them. The mail
   domain `itsm.sogode.com` is ruby's: MX, SPF and DKIM are public records,
   checked by `shared/ruby-mail-domain.sh itsm.sogode.com helpdesk@itsm.sogode.com`
   on ruby.

## Monitoring

- `node` and `alloy` jobs as every enrolled host; nginx logs to the journal,
  so `{host="glpi"}` in Loki has them. GLPI's own logs stay in `/var/log/glpi`.
- The blackbox probe `kind="service", service="glpi"` reads
  `https://itsm.sogode.com/status.php`, which reports the database, the file
  directories, cron and the mail collector, and alerts as `lab-service-unhealthy`
  on any `PROBLEM`.
- Its certificate is probed with the rest (`lab-tls-failing`, `lab-cert-expiring`).

## Building it

The guest came first, in its own merge, because CI runs Ansible before OpenTofu.
In order:

1. The router reservation `BC:24:11:47:4C:50` → 192.168.8.63, by the owner.
2. The guest (`infra/tofu`): Tofu writes talos's deploy key into it at creation,
   with the restrictions `deploy-access.yml` gives it, so apply-on-merge reaches
   it from its first boot.
3. Its host key pinned in `infra/ansible/known_hosts`; the mailbox on ruby; the
   secrets filled and imported, and `deploy-access.yml` run so talos has them –
   from the branch that adds them, since `main` does not list them yet.
4. The service: `FLEET`, DNS, the role, monitoring – one merge, applied by the
   runner in the order enrol, fleet, monitoring, dns, apps.
5. **`ca.yml` by a person, then a re-run of that merge's job.** talos may mint
   a new host only its `.home` name and lab addresses; `itsm.sogode.com` is
   allowed once `ca.yml` has put glpi and its `FLEET` names on pistis's lists.
   The first apply was refused for exactly that on 12 November 2026. Running
   `ca.yml` from the branch before merging avoids the re-run.
6. `offsite.yml --limit glpi`, by a person.
