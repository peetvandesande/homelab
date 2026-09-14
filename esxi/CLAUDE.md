# esxi

`esther`, the ESXi 8.0.3 host at **192.168.1.20**, logging to Loki. It is not
a container and not Proxmox — it is the one machine in the lab that cannot run
Alloy, so it gets two mechanisms, both of which live on the loki container
(192.168.1.56), the *relay*:

- **Syslog**: ESXi's own vmsyslogd forwards over TLS to an Alloy
  `loki.source.syslog` listener on `:1514`, verifying the relay against the
  lab CA (`/etc/vmware/ssl/castore.pem`).
- **SMART**: ESXi has no exporter, so `esxi-smart.timer` on the relay pulls
  `esxcli storage core device smart get` over SSH hourly and pushes one
  logfmt line per disk to Loki as `{host="esther", job="esxi-smart"}`.

## Working on this

`relay/` mirrors the loki container's filesystem — not esther's — and holds
only the ESXi-specific pieces (`esxi.alloy`, the puller, its units). The
container's own stack is `loki/`; its fleet Alloy file is `alloy/`.

- `scripts/deploy.sh` pushes `relay/` to .56, generates the puller's SSH key
  there if missing, and proves the listener handshakes.
- `scripts/configure-host.sh` does the ESXi side over SSH: installs the
  puller key (and the workstation key, if it is one esther accepts - see
  invariant 4), appends the CA chain to castore.pem, points syslog at the
  relay, opens the firewall. Needs SSH enabled on esther first.
- `scripts/verify.sh` asks Loki whether esther's syslog and SMART are
  arriving.

Order: `alloy/scripts/deploy.sh` (once, for directory mode) → `deploy.sh` →
`configure-host.sh` → `verify.sh`.

## Dashboard

`grafana/root/var/lib/grafana/dashboards/esxi.json`, at
https://192.168.1.54:3000/d/esxi. Loki-only, because esther has no exporter:
SMART health, drive temperature (with the drive's own limit where esxcli
reports one), bad-sector totals, power-on time and a below-threshold counter
from the `esxi-smart` job, plus severity/source volume and error, vmkernel
and smartd log panels from the syslog job. The SMART stats read
`last_over_time(... [2h])`, so one missed hourly run is tolerated and the
second shows as "no data" - which is the correct thing for it to show.
Deploy with `grafana/scripts/deploy.sh`.

## Invariants

1. **`?formatter=RFC_5424` on the loghost is not optional.** ESXi's default
   is RFC 3164 with RFC 3339 timestamps, which Alloy's rfc3164 parser rejects
   outright. ESXi 8.0 U2 IA emitted malformed RFC 5424 structured data; 8.0.3
   does not. After an ESXi update, parse warnings in the relay Alloy's
   journal are the first thing to look for.

2. **Same labels as the journal-shipped hosts**: `host` (short name, the
   domain stripped), `identifier` (the syslog app name — Hostd, vmkernel,
   vpxa), `level` (severity, rewritten to journald's spellings). No `unit`,
   because ESXi has none. One LogQL query spans the fleet and esther alike.

3. **`esxi.alloy` forwards into the fleet file's `loki.write.loki`.** It
   declares no writer of its own; component names must be unique across the
   directory. It exists only on the relay, which is why `alloy/` is in
   directory mode.

4. **The puller's key never leaves the relay, and it is ECDSA P-256.**
   Generated on .56 by `deploy.sh`; `configure-host.sh` reads the public half
   from there. ESXi 8 runs sshd in FIPS mode and offers only `rsa-sha2-*` and
   `ecdsa-sha2-nistp256` - an ed25519 key is refused with "Permission denied
   (publickey,keyboard-interactive)" and nothing in esther's UI says why. The
   same goes for the lab's ed25519 workstation key, so `configure-host.sh`
   prompts for root's password. SSH stays enabled on esther as a consequence,
   key-only, with the Host Client's shell warning silenced by choice, not by
   default.

5. **The relay pushes SMART straight to Loki's API with esther's labels**,
   rather than logging to its own journal — which would label the lines as
   `host="loki"`.

## SMART line shape

```
model="WDC WD40EZAZ-00S" health_status=OK read_error_count=0 read_error_count_threshold=51 power_on_hours=55 power_on_hours_raw=33171 drive_temperature=42 ...
```

esxcli 8.0.3 prints Value, Threshold, Worst and Raw per attribute, and
Value means different things per attribute: ATA-normalised (1-253, failing
at or below Threshold) for some, a repeat of Raw for most, and on NVMe the
thresholds are maxima. So each attribute goes out as `<key>=Value`, with
`<key>_raw=` where Raw differs and `<key>_threshold=` where there is one.
`below_threshold=` lists only attributes that are demonstrably normalised
(Raw present and different) and at or below their threshold - the naive
"value <= threshold" rule fired on a healthy disk's `read_error_count=0`
against its threshold of 51. Alert on
`{host="esther", job="esxi-smart"} |= "below_threshold"`, on
`health_status!="OK"`, or per attribute with logfmt in Grafana, e.g.
`drive_temperature >= drive_temperature_threshold`. Only Direct-Access
devices are pulled; the optical drive has no SMART.
