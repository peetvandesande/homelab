# wifi-watchdog

A watchdog on the router (192.168.8.1) that runs `wifi reload` when a radio's
station table goes stale. The mt7990 driver leaks a station entry on an MLO
teardown: hostapd keeps listing a client the driver has no record of, so that
client is associated but may carry no traffic. `wifi reload` clears it without
taking the WAN and the ONT down, which a reboot does. On 21 October 2026 one
leak cost an evening of unusable Wi-Fi; `wifi-sta-table-stale` in `grafana/`
was written after it, and this automates the fix that alert asked for.

```
router/usr/local/bin/wifi-watchdog   the watchdog itself
scripts/deploy.sh                    the script and its cron entry
scripts/verify.sh                    installed, triggered, and reaches Loki
```

It lives outside `router/` for the same reason as `wan-watchdog/`: `router/`
holds no config and has no deploy script.

## How it decides

Every minute, from cron:

1. **Count `sta not found` lines in the last 10 minutes** of `logread`. The
   driver logs one per stale entry each time something asks for the station
   list – `router-metrics` on lenora does, once a minute – so one leak is about
   10 lines per 10 minutes and a healthy radio is 0.
2. **More than 5 is a leak**, the same threshold as `wifi-sta-table-stale`.
   That rule waits 15 minutes before firing, so the watchdog acts first and the
   alert only fires if the reload did not hold.
3. **Then `wifi reload`**, logged at warn as `forcing wifi reload: <n> 'sta not
   found' in 600s on <bands>`. Every Wi-Fi client drops for a few seconds.
4. **At most once an hour.** A leak that comes straight back is not fixed by
   reloading on a timer, so the watchdog stays quiet and the alert says so.

## Invariants

1. **The window is in uptime, not wall-clock.** Each kernel line carries the
   uptime in brackets, which `/proc/uptime` compares against directly: no date
   parsing, and an NTP step cannot shift the window.

2. **Lines from before the last reload never count.** The window starts at the
   later of 10 minutes ago and the last reload, so the lines that caused one
   reload cannot cause the next.

3. **State is one integer in `/tmp`, parsed, not sourced** – the uptime of the
   last reload. A reboot clears it, which is right: a reboot also clears the
   table. A value above the current uptime is from before a reboot and is
   ignored.

4. **One run at a time, via `flock -n`**, so a slow reload and the next cron
   tick cannot overlap.

5. **It depends on `router-metrics` polling.** With nothing asking the driver
   for its station list, a leak logs nothing and the watchdog never sees it.
   `verify.sh` checks lenora's `homelab-router-metrics.timer` for that reason.

## Seeing it act

**`wifi-watchdog-acting`** in `grafana/` counts the `forcing` lines from
`{host="router", identifier="wifi-watchdog"}`, so a reload that fixed the
problem still tells you it happened. `verify.sh` sends a marker line and
asserts it arrives in Loki under that label. It never runs the real script:
with a leak present, that would reload the radios.

## Testing it

Run a copy with the reload faked; it reports what it would do against the
live log and leaves the radios alone:

```sh
sed -e 's#^STATE=.*#STATE=/tmp/wd-test.state#' -e 's#^LOCK=.*#LOCK=/tmp/wd-test.lock#' \
    -e 's#^wifi reload .*#echo FAKE wifi reload#' -e 's#^warn() .*#warn() { echo "WARN: $1"; }#' \
    router/usr/local/bin/wifi-watchdog \
  | ssh root@gw 'cat > /tmp/wd-test && chmod +x /tmp/wd-test && /tmp/wd-test; rm -f /tmp/wd-test*'
```
