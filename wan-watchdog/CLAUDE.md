# wan-watchdog

A watchdog on the router (192.168.8.1) that forces a fresh DHCP exchange when
the WAN is up but dead. It exists for one specific failure, described in full
in `router/ORANGE.md`, "A dead session behind a live interface": a PON
re-registration leaves the Orange session dead one way while netifd still holds
a valid lease, and because `eth1.832` never loses carrier there is no `ifdown`,
so udhcpc never rebinds. On 23 October 2026 that cost 88 minutes, ended by a
reboot.

```
router/usr/local/bin/wan-watchdog           the watchdog itself
router/etc/hotplug.d/kmwan/99-wan-watchdog  GL's tracker as an early trigger
scripts/deploy.sh                           both files, the cron entry, sysupgrade.conf
scripts/verify.sh                            installed, triggered, and does it decline to act
```

## Why this is not in `router/`

`router/` holds no config, deliberately, and must not grow a `deploy.sh` — see
its `CLAUDE.md`. This is a file pushed to the device, so it lives in its own
top-level directory with its own deploy script, the same way `router-metrics/`
does. It is not *in* `router-metrics/` either, because that directory's first
invariant is that it is read-only on both devices, and this thing's whole
purpose is to act.

## How it decides

```
cron, every minute ─┐
                    ├─> probe 1.1.1.1 and 8.8.8.8, bound to the WAN device
kmwan offline event ┘        │
                             ├─ reachable ──> silent, state file removed
                             └─ 3 sweeps dead, wan still "up" ──> ifup wan wan6
```

1. **If netifd says the interface is down, it does nothing.** netifd is already
   retrying, and an `ifup` from here would fight it. The failure this exists
   for reports itself as *up* — that is the whole point.
2. **The probe is bound to the WAN device** (`ping -I eth1.832`), so it tests
   the WAN path rather than whatever the VPN policy routing would have chosen
   for those addresses. Verified: the same ping bound to `br-lan` or `lo`
   fails, so `-I` is doing something.
3. **Three consecutive dead sweeps before acting** — a minute apart, so about
   three minutes. One failed sweep is not evidence.
4. **Then `ifup wan` and `ifup wan6`.** Both sit on `eth1.832`; v6 does not
   come back on its own.
5. **The backoff doubles, 120 s to a 30-minute cap.** A genuinely cut fibre
   must not be `ifup`'d every minute for hours.

## Invariants

1. **It must only ever act when `wan` reports up.** That condition is what
   separates this from netifd's job. Remove it and the watchdog starts racing
   netifd's own retries on every ordinary WAN bounce.

2. **State lives in `/tmp`, and that is deliberate.** A reboot clears it,
   which is correct: a reboot is itself the fix, so the backoff should not
   survive one. The file is three integers, one per line, and is **parsed, not
   sourced** — it sits in a world-writable directory and sourcing it would be
   an execution path.

3. **One run at a time, via `flock`.** The cron tick and the hotplug hook both
   call it and an `ifup` is slow enough for them to overlap. The script
   re-execs itself under `flock -n`, which exits without running anything if
   the lock is held. `verify.sh` asserts a second run declines.

4. **The hotplug hook only wakes it; it does not authorise anything.** kmwan
   declares the WAN offline for its own reasons and can flap. The hook
   contributes one sweep and the threshold and backoff still apply, so a
   flapping tracker cannot force an `ifup` on its own.

5. **The targets are shared with kmwan and the blackbox exporter**, which is
   intentional — `1.1.1.1` and `8.8.8.8` are the first two of kmwan's four
   trackers and the two the blackbox `internet` probe pings. `router/CLAUDE.md`
   invariant 10 already requires the `doh_resolvers4/6` sets to stay
   :443-only for the blackbox probe's sake; the same constraint now protects
   this. The router's own output is not subject to those forwarding rules, but
   keep the two facts together: if these addresses ever stop answering ICMP,
   this watchdog starts forcing an `ifup` on a healthy line every 30 minutes.

6. **Both installed files are outside the package set**, so a sysupgrade drops
   them unless they are listed. `/usr/local/bin/` was already in
   `/etc/sysupgrade.conf` (for `router-metrics` and `vpn-policy-dump`); the
   hotplug hook is added by name. `/etc/crontabs/` needs nothing — it is in
   `/lib/upgrade/keep.d/busybox`. `deploy.sh` is idempotent and is what to run
   after a factory reset.

## It is invisible when it works

A healthy sweep logs nothing and leaves no state file, so there is no positive
signal that it is alive — hence `verify.sh`, which asserts the mechanism
rather than the outcome: the files match this repo, cron holds the entry,
crond runs, kmwan is still tracking `wan`, a sweep exits 0 silently, a second
run declines while the lock is held, and a logged line really does arrive in
Loki as `{host="router", identifier="wan-watchdog"}`.

That last one matters because the alert depends on the label.
**`wan-watchdog-acting`** in `grafana/` counts the `forcing` lines, so a
watchdog that repairs the fault in three minutes still tells you the line
flapped instead of papering over it silently. The router has no textfile
collector to publish to — it cannot run node-exporter — which is why that
alert reads a log line; `grafana/CLAUDE.md` invariant 11 covers both rules
that do.

## Testing the failure path

Do not break the real WAN. Copy the script aside with unroutable targets
(RFC 5737 TEST-NET answers nothing) and a fake `ifup` earlier in `PATH`:

```sh
ssh root@192.168.8.1
sed -e 's|^TARGETS=.*|TARGETS="192.0.2.1 198.51.100.1"|' \
    -e 's|^STATE=.*|STATE=/tmp/ww-test.state|' \
    -e 's|^LOCK=.*|LOCK=/tmp/ww-test.lock|' \
    /usr/local/bin/wan-watchdog > /tmp/ww-test && chmod +x /tmp/ww-test
mkdir -p /tmp/ww-bin && printf '#!/bin/sh\necho "FAKE ifup $1"\n' > /tmp/ww-bin/ifup
chmod +x /tmp/ww-bin/ifup
PATH=/tmp/ww-bin:$PATH; for n in 1 2 3 4; do WAN_WATCHDOG_LOCKED= /tmp/ww-test; done
logread | grep wan-watchdog | tail -4
rm -rf /tmp/ww-test /tmp/ww-test.state /tmp/ww-test.lock /tmp/ww-bin
```

Sweeps 1 and 2 log `sweep n/3` at notice, sweep 3 logs `forcing ifup wan wan6`
at warn and calls the fake, and sweep 4 is silent because the backoff holds.
Clearing `WAN_WATCHDOG_LOCKED` is needed because the real script exports it
when it re-execs under `flock`.
