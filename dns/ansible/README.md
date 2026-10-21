# Zone management with Ansible

One place to describe every zone Pythia serves from its **bind** backend, and
one command to render, push and reload it.

This is the only Ansible in the repo. The rest of `dns/` is unchanged:
`scripts/deploy.sh` still pushes `pythia/`, `delphi/` and `themis/` wholesale
and is still what builds the stack. This playbook narrows in on the one thing
that was fiddly and easy to get wrong by hand — zone data.

## What it does

```sh
cd dns/ansible
ansible-playbook zones.yml                   # render, push, reload
ansible-playbook zones.yml --check --diff    # preview; touches nothing
ansible-playbook zones.yml --tags render     # rewrite the repo files only
ansible-playbook zones.yml --tags push       # push what the repo already holds
```

`group_vars/all.yml` is the source of truth: one `zones` list, any number of
entries, in either backend. The playbook renders it into `dns/pythia/var/lib/powerdns/zones/` and
`dns/pythia/etc/powerdns/bindbackend.conf` — the files this repo already
carried — then copies those to Pythia and reloads only the zones that changed.
So:

- `git diff` is the review step, as it is for everything else here.
- `scripts/deploy.sh` keeps pushing exactly the files it always did, and the
  two do not fight over the host.

## The shape of the data

Every entry in `zones` has a `kind`:

| `kind`     | What it is                               | Needs                  |
|------------|------------------------------------------|------------------------|
| `forward`  | named records in commented sections      | `sections`             |
| `reverse`  | PTRs, generated                          | `prefix` (a /24)       |
| `override` | split-horizon override of a single name  | `records`              |

... and a `backend`, which decides how it is managed:

| `backend` | Where it lives | Managed by                                   |
|-----------|----------------|----------------------------------------------|
| `bind`    | a zone file in this repo | rendered, pushed, reloaded; serial handled here |
| `api`     | gsqlite3 on Pythia | created and patched over the HTTP API; serial handled by PowerDNS |

There can be as many of each as you like, which is what makes additional
forward zones and a lab's worth of reverse zones ordinary rather than special.
A `reverse` zone's `prefix` selects the A records that become its PTRs, taken
from **every** forward zone in the list — so each PTR names the forward zone
the record actually came from, and a lab's forward and reverse zones stay in
step with each other for free.

## What it buys over editing the zone files

- **PTRs are generated.** Every A record inside a reverse zone's `prefix` gets
  its reverse entry automatically, from whichever forward zone declares it.
  "Keep the reverse zone in step with the forward zone" is no longer a step
  anyone can forget. `ptr: false` on a record opts out.
- **Serials bump themselves, and only when something changed.** The template
  emits a placeholder; the rendered body is compared against the file on disk
  with its serial masked out the same way. Unchanged zone, untouched serial,
  nothing reloaded. Changed zone, `YYYYMMDDnn`, never going backwards.
- **Only the zones that changed are reloaded**, with
  `pdns_control bind-reload-now <zone>`. `pdns_control rediscover` runs only
  when `bindbackend.conf` changed, which is what adding or removing a zone
  looks like.
- **Invariant 5 is checked before anything is written.** A split-horizon
  override needs three pieces and SERVFAILs with two. The playbook reads
  `delphi/etc/powerdns/recursor.yml` and `recursor.lua` out of the repo and
  refuses to render a zone that is not forwarded to Pythia and does not have a
  negative trust anchor.

  Both checks match **up the tree**, because a forward and an anchor cover
  everything beneath them: `openstack.home` is wired up by `home.` and needs
  nothing of its own. The anchor check also expands the
  `for i = 32, 39 do addNTA(i .. ".168.192.in-addr.arpa.")` loop in
  `recursor.lua`, so the lab reverse zones pass on the strength of the loop
  rather than needing eight lines written out.

  It also refuses an override name with fewer than three labels, so nobody
  accidentally overrides `peetvandesande.com` and shadows the whole domain, and
  refuses two zones sharing a name.
- **Every zone is parsed by the server afterwards**, with `pdnsutil check-zone`
  — a zone that fails to load otherwise just quietly stops answering.

## Adding a name

Add it to the right section of the `home` zone's `sections` in
`group_vars/all.yml`:

```yaml
- { name: thalia, data: 192.168.8.58, comment: 'what it is' }
```

Then `ansible-playbook zones.yml`. The PTR, both serials and the reload are
handled. The record's `comment:` becomes the trailing `;` comment in the zone
file, and `ptr_note:` emits a standalone comment line above its PTR.

`type:` defaults to `A`; `CNAME` and `AAAA` work the same way. An AAAA gets no
PTR — there is no reverse zone for the delegated prefix, which changes with the
router.

## Managing a zone on the bind backend

This is the full procedure. Steps 1 to 3 are all required, and the playbook
refuses to run if step 2 is missing.

**1. Declare it in `zones`, in `group_vars/all.yml`.** Every entry needs a
`name`, a `kind`, a `backend`, and whatever that kind requires — `sections` for
a forward zone, `prefix` for a reverse one, `records` for an override:

```yaml
  - name: 40.168.192.in-addr.arpa
    kind: reverse
    backend: bind
    prefix: 192.168.40
    comment: Reverse zone for 192.168.40.0/24.
```

The name must not already exist in the gsqlite3 backend. Two backends holding
one zone is not an error PowerDNS reports — the gsqlite3 copy answers while it
exists and the bind copy takes over when it goes. Check first:

```sh
ansible -i inventory.yml pythia -m shell -a \
  'key=$(sed -n "s/^api-key=//p" /etc/powerdns/pdns.conf); \
   curl -sS -H "X-API-Key: $key" http://127.0.0.1:8181/api/v1/servers/localhost/zones'
```

**2. Wire it up on Delphi**, in two files, unless an ancestor zone already
covers it — `home.` covers `openstack.home`, and the `for i = 32, 39` loop
covers the lab reverse zones:

- `delphi/etc/powerdns/recursor.yml` — a `forward_zones` entry with
  `recurse: false` and forwarder `192.168.8.52`.
- `delphi/etc/powerdns/recursor.lua` — `addNTA("<zone>.", "<why>")`.

The playbook reads both **out of the repo**, not off Delphi, so its checks pass
as soon as you have edited them. Neither is optional: without the forward,
Delphi recurses to the internet instead of asking Pythia; without the anchor,
every lookup SERVFAILs. See `dns/CLAUDE.md` invariants 4 and 5.

**3. Deploy Delphi.** This playbook does not push it:

```sh
cd .. && ./scripts/deploy.sh
```

**4. Run the playbook.**

```sh
cd ansible && ansible-playbook zones.yml
```

It renders `pythia/var/lib/powerdns/zones/<name>.zone` and a block in
`pythia/etc/powerdns/bindbackend.conf`, pushes both to Pythia, runs
`pdns_control rediscover` because `bindbackend.conf` changed, reloads each
changed zone with `pdns_control bind-reload-now`, and finishes with
`pdnsutil check-zone` over every zone that exists.

**5. Commit the generated files.** They are tracked, and `scripts/deploy.sh`
pushes them too, so a checkout that disagrees with the YAML will be pushed by
the next deploy.

### Writing the records

`type` defaults to `A`. `@` is the zone apex. A record's `comment` becomes the
trailing `;` comment in the file and `ptr_note` a standalone comment line above
it. The SOA and NS come from `soa` in `group_vars/all.yml` — don't write them
as records.

The serial is this playbook's to manage: date-based `YYYYMMDDnn`, moved only
when that zone's contents actually changed. Hand-editing a zone file is
pointless, since the next render overwrites it.

A reverse zone generates its PTRs from the A records of **every** forward zone
in the list, whichever backend they are in, whose address falls inside its
`prefix`. `ptr: false` on a record opts out.

### Removing a zone

Deleting the entry from `zones` is **not** enough, and does not do what you
might expect. Four things, in this order:

1. Remove the entry from `zones`, and run the playbook. The zone drops out of
   `bindbackend.conf`, the push triggers `rediscover`, and PowerDNS stops
   serving it.
2. **Delete the zone file yourself, in both places.** Nothing prunes orphans:
   `git rm pythia/var/lib/powerdns/zones/<name>.zone`, and remove
   `/var/lib/powerdns/zones/<name>.zone` from Pythia.
3. Remove the `forward_zones` entry and the `addNTA()` from Delphi, and
   `./scripts/deploy.sh`. Leaving them is worse than untidy: Delphi keeps
   forwarding the zone to a Pythia that no longer serves it, so those names
   fail outright rather than falling back to whatever the internet says. For a
   split-horizon override that is the difference between reverting to the
   public answer and breaking the name for the whole LAN.
4. `./scripts/verify.sh`.

## Adding a split-horizon override

Add an entry to `zones` with `kind: override` and `backend: bind`, then follow
the procedure above — the Delphi half is not optional, and the playbook will
refuse to run until it is there. `dns/CLAUDE.md` invariant 5 explains why a
signed parent domain makes the anchor mandatory rather than merely tidy.

The zone must be the **exact name** you are overriding, never its parent. The
playbook refuses a name with fewer than three labels for this reason: a zone
for `peetvandesande.com` would shadow mail, www and everything else in the
domain with an empty internal zone, for the whole LAN.

## Lab zones

The Proxmox labs share `192.168.32.0/21`, one lab at a time, and register their
own names at runtime — so their zones are `backend: api` and live in gsqlite3.
The bind backend could not hold them even if we wanted it to: PowerDNS's API
implements no zone creation or record writes against it, which is the entire
reason that second backend exists.

What the playbook guarantees for an api zone is that it **exists**, with the
SOA and NS this repo specifies, plus whichever records the YAML declares. What
it will not do:

- **It never deletes a zone**, and never issues a full-zone replace.
- **It only ever REPLACEs rrsets it declares.** A name the YAML does not
  mention is not ours — REPLACE on it would delete whatever the lab put there.
  Declaring no records at all, as the lab zones do today, means the playbook
  touches nothing inside the zone.
- **It never manages the SOA after creation.** With `soa_edit_api` the serial
  moves on every change, so a managed SOA would differ on every run and bump
  the serial forever.
- **It patches only what differs.** The declared rrsets are compared against
  what the server holds, ignoring record order, and an unchanged zone is left
  alone — otherwise every run would bump the serial.

So the split is: this repo owns the skeleton, the lab owns its own records.

**One thing to check on the lab side.** The playbook now creates these zones if
they are absent, which means a lab's bootstrap may find `openstack.home`
already there and get `409 Conflict` from its own `POST /zones`. If the
bootstrap is not idempotent about that, either make it tolerate an existing
zone or drop its create and let it go straight to patching records.

## What it deliberately does not manage

- **The lab's own records.** See above — only the skeleton is ours.
- **`pdns.conf`, Delphi and Themis.** `scripts/deploy.sh` owns those.
- **DNSSEC.** These zones are unsigned by design; Delphi carries an NTA for
  each one.

## Layout

```
ansible.cfg                     self-contained; run ansible-playbook from here
inventory.yml                   pythia (by IP) plus localhost for the render
group_vars/all.yml              THE ZONE DATA - one `zones` list
zones.yml                       the playbook: render, then push
roles/powerdns_zones/
  tasks/main.yml                asserts + render, on localhost
  tasks/zone.yml                one zone: render, compare, settle the serial
  tasks/push.yml                copy to Pythia, reload what changed, check
  tasks/api_zone.yml            one api zone: create if absent, patch what differs
  templates/                    header, SOA, one per kind, bindbackend, rrsets
```

Hosts are addressed by IP, as the rest of the repo is: a container resolves its
own FQDN to `127.0.1.1`, so names are not safe to address hosts by from inside
one.
