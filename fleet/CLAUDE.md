# fleet

Host hygiene that applies to **every enrolled host** and belongs to no single
service: today, the units that are masked everywhere.

It exists because the alternative was worse. `openipmi.service` was failed on
all eleven hosts, which made the `systemd-unit-failed` alert in `grafana/`
useless — it had to exclude the one thing that was actually failing. Masking it
by hand fixed the symptom but nothing reapplied it, so a newly built container
would quietly bring it back.

This is not a service stack and has no `root/` tree: there is nothing to push,
only state to assert. That is why it does not follow the
one-directory-per-container shape.

## Working on this

`masked-units` is the source of truth. `scripts/deploy.sh` masks everything
listed, on every host in the fleet; `scripts/verify.sh` asserts it stuck and
that no host has a failed unit.

```sh
./scripts/verify.sh                 # is the fleet clean?
./scripts/deploy.sh                 # apply everywhere
./scripts/deploy.sh 192.168.8.52    # just one host, after rebuilding it
```

Independent of every other stack's deploy order — it touches nothing another
directory owns, so run it whenever.

## Invariants

1. **The fleet list is read out of `ca/scripts/enrol.sh`, not copied here.**
   That list is already duplicated in `prometheus.yml`'s `node` job and in
   `node-exporter/`'s `FLEET`, and a third copy to forget is not an
   improvement. `scripts/deploy.sh` parses the `FLEET=(...)` block, so adding a
   host there is enough.

2. **`reset-failed` follows every `mask`.** Masking does not clear a state that
   has already gone to failed, and a unit left failed is exactly what the
   Grafana alert fires on — so masking alone would leave the alert firing and
   look like the fix had not worked.

3. **Deploy masks; it never unmasks.** Deleting a line from `masked-units` does
   not undo anything — unmask it by hand. The alternative is a script that
   unmasks whatever it does not recognise, and a Debian LXC arrives with a
   dozen masked units it knows nothing about (`cryptdisks`, `hwclock`,
   `x11-common`, `sys-kernel-*`, `systemd-journald-audit.socket`, plus `zfs-*`
   and `nfs-common` on lenora). Silently unmasking those would be a far worse
   failure than a stale line in a file.

   For the same reason deploy does **not** report units that are masked but
   unlisted. That set is pre-existing baseline, not drift, and printing eleven
   copies of it on every run only teaches you to stop reading the output.

4. **A failed unit that is not in `masked-units` is a WARN, not a FAIL.** It is
   a real fault somewhere else in the lab — someone else's to fix — but you
   should still see it here, because this is the directory that claims the
   fleet is clean.

## What is masked, and why

`masked-units` carries the reason against each entry. At present that is
`openipmi.service` alone: it arrives as a dependency of `ipmitool`, the unit is
an LSB init script that loads the in-band IPMI driver, and there is no
`/dev/ipmi*` on any host — lenora included, so the BMC on that board is not
exposed in-band either. For in-band `ipmitool` on lenora, unmask it and load
`ipmi_si`/`ipmi_devintf`; out-of-band over LAN never needed this unit.

Masking rather than `apt remove ipmitool` is deliberate: it is reversible, it
does not fight the package manager, and `ipmitool` itself is still there if
someone wants to talk to a BMC over the network.

## Verified

The enforcement loop was tested rather than assumed: unmasking and starting
`openipmi` on pythia made `verify.sh` fail that host (and warn about the failed
unit), `deploy.sh 192.168.8.52` repaired it, and the fleet-wide failed-unit
count in Prometheus went back to zero on the next scrape.
