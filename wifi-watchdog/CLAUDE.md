# wifi-watchdog

A watchdog on the router (192.168.8.1) that removes stale stations from
hostapd's client table. The mt7990 driver drops a station on an MLO teardown
without hostapd hearing of it, so hostapd keeps listing a client the driver
has no record of, and that client is associated but may carry no traffic. On
21 October 2026 one leak cost an evening of unusable Wi-Fi;
`wifi-sta-table-stale` in `grafana/` was written after it, and this clears
what that alert reports.

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
   alert fires only if it did not hold.
3. **Find the stale addresses**: on each `hostapd.*` interface, the clients
   `ubus call hostapd.<if> get_clients` lists and `iw dev <if> station dump`
   does not. Looked at twice, 3 seconds apart; only an address stale both
   times counts.
4. **Deauth each one through hostapd** (`del_client`, reason 1, no ban), logged
   at warn as `forcing deauth of <mac> on <if>`. hostapd drops the entry after
   its 5-second deauth delay and the client associates afresh. Nobody else is
   touched.
5. **Then wait 15 minutes** before acting again, so it can never loop.

## Invariants

1. **`wifi reload` does not fix this, and must not come back as the remedy.**
   On this firmware it is GL/MediaTek's Lua `/sbin/wifi`, which reapplies
   config and leaves hostapd's table alone. The first version of this
   watchdog ran it on 3 November 2026; the stale entry outlived it and
   `sta not found` carried on every minute. The deauth cleared it at once.

2. **An empty driver list is skipped, never treated as "all stale".** If `iw`
   fails or a radio is mid-restart, the station dump is empty and every
   hostapd client would look stale. `stale_on` returns nothing then. This
   matters more than it looks: busybox's `grep -vxF -f` with an empty pattern
   file prints nothing, which hides the case rather than handling it.

3. **The window is in uptime, not wall-clock.** Each kernel line carries the
   uptime in brackets, which compares directly against `/proc/uptime`: no
   date parsing, and an NTP step cannot shift the window. Lines from before
   the last action never count.

4. **State is one integer in `/tmp`, parsed, not sourced** – the uptime of the
   last action. A reboot clears it, and clears the table too. A value above
   the current uptime is from before a reboot and is ignored.

5. **One run at a time, via `flock -n`.**

6. **It depends on `router-metrics` polling.** With nothing asking the driver
   for its station list, a leak logs nothing and the watchdog never sees it.
   `verify.sh` checks lenora's `homelab-router-metrics.timer` for that reason.

## Seeing it act

**`wifi-watchdog-acting`** in `grafana/` counts the `forcing` lines from
`{host="router", identifier="wifi-watchdog"}`, so a repaired leak still tells
you it happened. Lines with no stale address to remove log `nothing done`
instead, at most once per cooldown, and the stale-table alert carries on.
`verify.sh` sends a marker line and asserts it arrives in Loki under that
label. It never runs the real script.

## Testing it

Run a copy with the deauth faked, the threshold at 0 and a made-up address
added to `rai2`'s hostapd list. It should name that address and nothing else:

```sh
sed -e 's#^STATE=.*#STATE=/tmp/wd-test.state#' -e 's#^LOCK=.*#LOCK=/tmp/wd-test.lock#' \
    -e 's#^THRESHOLD=.*#THRESHOLD=0#' \
    -e 's#ubus call "hostapd.$ifc" del_client#echo FAKE del_client "$ifc"#' \
    -e 's#^warn() .*#warn() { echo "WARN: $1"; }#' \
    -e 's#| sort > /tmp/wifi-watchdog.h#| sort > /tmp/wifi-watchdog.h; [ "$1" = rai2 ] \&\& echo de:ad:be:ef:00:01 >> /tmp/wifi-watchdog.h#' \
    router/usr/local/bin/wifi-watchdog \
  | ssh root@gw 'cat > /tmp/wd-test && chmod +x /tmp/wd-test && /tmp/wd-test; rm -f /tmp/wd-test*'
```
