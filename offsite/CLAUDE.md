# Off-site copy

restic to Hetzner Object Storage in Helsinki, the copy that survives the house
and sally together, and malware in the lab. Task 19 in `infra/README.md`.

| Host | What | Size, November 2026 |
|---|---|---|
| lexie | `/home/shared/pictures`, `Giulia`, `videos` | about 27 GB |
| moby | Nextcloud: a `pg_dump`, then the volume without previews or logs | about 19 GB |
| forgejo | a `pg_dump`, then `/var/lib/forgejo` and `/etc/forgejo` | under 40 MB |

XWiki is left out for now, by choice. Everything else is rebuilt from this repo.

## Working on this

`root/` mirrors what is installed on each host. `infra/ansible/offsite.yml`
installs it and says what each host backs up; it is **run by a person only**,
because the secrets are in `homelab-restricted` (`infra/README.md`, "Secrets"),
and `infra/scripts/apply.sh` lists any change here as needing one.
`tests/` covers the lock renewal and runs in CI.

One script, `/usr/local/sbin/offsite`, does everything:

| Command | Where, when | Does |
|---|---|---|
| `backup` | all three, nightly 03:30-04:00 UTC | the dumps, then the paths |
| `maintain` | lexie, Sundays 07:00 UTC | forget, prune without repacking, renew the locks, measure the bucket |
| `test` | lexie, first Sunday 09:00 UTC | read 5 GB of packs, restore both dumps and 20 of lexie's files and compare them |
| `undelete --since T` | by a person | see "After a deletion" |

Each writes `offsite_*.prom` into the textfile collector. `journalctl -u
offsite-backup` (or `-maintain`, `-test`) on the host says what happened.

## The bucket

`hel1.your-objectstorage.com`, bucket and keys in Bitwarden as
`offsite/RESTIC_REPOSITORY`, `offsite/RESTIC_PASSWORD`, `offsite/AWS_ACCESS_KEY_ID`
and `offsite/AWS_SECRET_ACCESS_KEY`. Without `RESTIC_PASSWORD` nothing in it can
be read, by anyone.

Versioning and Object Lock were set when it was created; on 10 November 2026 a
default retention of **90 days in compliance mode** was added. A test object,
`lock-test/2026-11-10.txt`, proved it: deleting the version is refused even
with the governance bypass header, shortening its lock is refused, and a plain
delete only adds a delete marker over a version that stays readable.

A lifecycle rule, `expire-noncurrent`, removes a version one day after it stops
being current, once its lock allows, and then the empty delete marker; without
it, what restic deletes would be billed for ever. The test object's version has
been non-current since 10 November, so it is also the proof that the rule
respects the lock: it must still be readable until 8 February 2027.

**Why the locks are renewed.** The default lock runs from upload, so a photo
uploaded once would become deletable 90 days later. `maintain` renews every
current version with under 80 days left back to 90, so anything current at a
weekly run stays undeletable for at least 73 days. What restic itself deletes
is no longer current, so it is not renewed and expires on its own. The renewal
uses the same key as restic: the key could extend a lock but never shorten one.

What this does not cover: someone with the Hetzner *account* login can close the
account. Its password and 2FA are in the owner's Bitwarden vault only, never in
the lab.

## First run

After `offsite.yml` has run, once, on lexie:

```
set -a; . /etc/offsite/offsite.env; set +a
RESTIC_CACHE_DIR=/var/cache/restic restic init
```

Then start `offsite-backup` on each host (`systemctl start --no-block
offsite-backup`) rather than waiting for the night; the first upload takes hours.
The alert rules in `grafana/` follow the first backup, because their staleness
rules treat NoData as alerting.

## Restoring

From any machine with restic and the four secrets:

```
restic snapshots                                   # --host lexie|moby|forgejo
restic restore <id> --target /restore --include /home/shared/pictures/2024
restic dump <id> /nextcloud.sql > nextcloud.sql   # the dumps are tagged "dump"
```

Downloads are billed beyond about 1.1 TB a month, so a full restore costs
nothing extra. After restoring Nextcloud's files, load the dump and run
`occ files:scan --all`: the dump is taken before the files, so a file newer
than it is otherwise invisible.

## After a deletion

Malware with the key can make the repository look empty by writing delete
markers. The versions beneath stay locked. Stop the timers on all three hosts
first, so nothing writes over the evidence, then:

```
offsite undelete --since 2026-11-10T00:00     # dry run: counts the markers
offsite undelete --since 2026-11-10T00:00 --apply
restic check
```

Pick a time before the damage started. Objects written since then are listed,
not changed: they can be a new snapshot of encrypted files, so restore from a
snapshot older than `T` and leave those alone.

## Pricing

As given by Hetzner on 10 November 2026, excluding VAT:

| Item | Price | Included |
|---|---|---|
| Base | €0.0104 per hour of runtime, at most €6.49 a month | – |
| Storage | €0.0087 per TB-hour beyond the included amount | 1 TB-hour per hour of runtime, so 1 TB held all month |
| Egress | €1.00 per TB beyond the included amount | 1.5 GB per hour of runtime, about 1.1 TB a month |
| Ingress, and traffic inside `eu-central` | Free | – |

- The included amounts are pooled over the month, not per hour.
- Every object is billed as at least 64 kB.
- Hetzner's own limits per bucket: 750 requests/s, 10 Gbit/s and 256 parallel
  sessions per source IP.

## Limits that follow from it

1. **Uploads are not throttled for cost.** Ingress is free. If a cap is ever
   needed it is to spare the home uplink, and is set from a measurement.
2. **Routine downloads are a fixed size, not a share**: the monthly `test`
   reads 5 GB of packs plus two dumps and 20 files, well under 1% of what is
   included, and cannot grow with the repository.
3. **A restore by a person is never throttled.** Restoring everything is inside
   the included egress; a slower restore saves nothing.
4. **Prune never repacks** (`--max-repack-size 0 --max-unused unlimited`).
   Repacking downloads packs and rewrites objects that Object Lock keeps
   anyway, so it costs egress and saves no storage.
5. **Keep restic's default pack size** (16 MiB). Smaller packs mean more
   objects, and anything under 64 kB is billed as 64 kB.
6. **Alert at 80% of the included storage**, measured by `maintain` over every
   version, since locked versions are billed until their lock expires. Egress is
   not measured – Hetzner exposes no figure – and is bounded by 2 and 3 instead.

At about 50 GB plus 90 days of locked versions, this stays inside the €6.49 base.
