# router-metrics

Metrics for the router (192.168.8.1) and the XGS-PON stick in its SFP cage
(192.168.11.1), neither of which can run node-exporter with a lab certificate.
lenora collects both every minute into its textfile collector, the same way
`homeassistant/` does for the HAOS VM, so they arrive on lenora's `node` target
as `homelab_router_*` and `homelab_ont_*`. The **Router and ONT** dashboard
(`homelab-router`) and the `router` alert group in `grafana/` use them; the
router's logs reach Loki separately (`router/README.md`, "Logs").

```
router/usr/local/bin/router-metrics          the read-only dump, on the router
lenora/usr/local/bin/homelab-router-metrics  parses it, writes router.prom
lenora/etc/systemd/system/...                its service and 1-minute timer
scripts/deploy.sh                            all of it, keys included
scripts/verify.sh                            is it collecting, and is it sane
```

## How it reaches the devices

```
lenora --ssh, key forced to router-metrics--> router --dbclient, key forced to pon--> ONT
```

1. **lenora's key** (`/root/.ssh/router_metrics`, comment
   `router-metrics@lenora`) is authorised on the router with
   `command="/usr/local/bin/router-metrics"` and no forwarding or pty – the
   same shape as Themis's `vpn-domain-sync` key. It can run the dump and
   nothing else.
2. **The router's key** (`/etc/dropbear/ont_metrics_key`, comment
   `router-metrics@router`) is authorised on the ONT with a forced command
   that prints the `pon` readings, one line per command. The ONT's
   `/etc/dropbear` is a link into `/ptconf`, which survives its reboots — but
   see invariant 6 for the part of that which is not true of the file.

`deploy.sh` creates both keys once and replaces their `authorized_keys` lines
by comment, so it is safe to rerun – and it is what to run after a router
factory reset or a replacement stick. The router script and the ONT key are
kept across firmware upgrades by `/etc/sysupgrade.conf` (`/usr/local/bin/`,
and the key by name).

Everything is parsed on lenora. The router side stays a few lines of shell
that print raw sections (`== ont`, `== hostapd rax2`, ...), because parsing
JSON in busybox ash is where scripts like this rot.

## Invariants

1. **Read-only on both devices.** The dump and the ONT command change
   nothing; keep it that way, since both keys are root on their device and the
   forced command is the only thing limiting them.

2. **MLO clients are named from the router's log.** An MLO client associates
   once per band with a random link MAC; hostapd reports only those, and the
   DHCP lease carries the client's own (MLD) address. Only the router's log
   ties them together – `wappd`'s `linkaddr:… mldaddr:…` on 4.11, the driver's
   `mac=…, mld(…addr=…)` on 4.9 – so a link that associated before the log last
   rolled shows as `client="unknown"` until it reassociates. The 2 MB ring
   buffer holds days; restarting `logd` empties it.

3. **`dbclient` needs `-T`.** Without it, run under a forced command with no
   terminal, it tries to set raw TTY mode, fails, and returns nothing – the
   ONT then simply looks down.

4. **Optics scaling is from `router/ORANGE.md`**: 0.002 dBm per LSB for Rx and
   Tx power, 1/256 °C, 100 µV. Bias scaling is unconfirmed, so it is exported
   raw as `homelab_ont_laser_bias_raw`.

5. **The ONT counters are since the stick booted**, not since the link came
   up, and reset with it. Use `increase()`; the absolute values say little.

6. **The ONT's `authorized_keys` must be written through, never replaced.**
   `/etc/dropbear` is a link to `/ptconf/8311/dropbear`, and `authorized_keys`
   inside it is a second link, to `/ptconf/8311/.ssh/authorized_keys`. A `mv`
   onto that path replaces the link with a regular file — which collects fine
   until the stick next reboots, because `_8311-sysinit.sh` runs `ln -fs` on
   every boot and the key goes with the file it discards. The stick reboots
   whenever the router does, the SFP cage being powered by it, so the two
   always fail together and the loss looks like the reboot's fault. `deploy.sh`
   truncates and rewrites the target; keep it that way. This cost an outage
   post-mortem on 22 October 2026: the key was deployed on 16 October, survived
   five days because nothing rebooted the stick, and vanished on the first
   reboot that happened — leaving `homelab_ont_up` at 0 and the "ONT not
   answering" alert firing, with the PON itself entirely healthy.
