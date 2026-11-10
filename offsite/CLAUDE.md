# Off-site copy

restic to Hetzner Object Storage, the copy that survives the house and sally
together. Task 19 in `infra/README.md`. Not built yet: this file holds the
pricing and the limits the build has to follow.

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
2. **Routine downloads have a budget of 10 GB a month**, under 1% of what is
   included: the monthly restore test and `restic check --read-data-subset`
   read a fixed size, not a percentage, so they cannot grow with the repository.
3. **A restore by a person is never throttled.** Restoring everything (about
   70 GB) is inside the included egress; a slower restore saves nothing.
4. **Prune never repacks** (`--max-repack-size 0 --max-unused unlimited`).
   Repacking downloads packs and rewrites objects that Object Lock keeps
   anyway, so it costs egress and saves no storage.
5. **Keep restic's default pack size** (16 MiB). Smaller packs mean more
   objects, and anything under 64 kB is billed as 64 kB.
6. **Alert at 80% of an included amount**: stored bytes against 1 TB, and the
   month's egress against 1.1 TB. Locked versions count as stored until their
   lock expires, so the stored figure is the bucket's, not the latest snapshot's.

At about 70 GB plus 90 days of locked versions, this stays inside the €6.49
base. Anything that pushes it past should be visible long before the bill.
