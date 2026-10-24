# Orange WAN (XGS-PON)

How the GL-BE14000 talks to Orange directly, without the Livebox. Working since
7 October 2026, IPv4 and IPv6. Credentials, the option 90 blob, cloned MACs and
the ONT identity are **not here** – they live in the router's `uci` and in
`~/projects/homelab-private/router/` (including the Livebox's own status page,
the reference for the ONT identity and optical levels).

## Hardware

| Item | Detail |
|---|---|
| ONT stick | `PAC-XGSPON-SFP` rev 1.0, **8311 community firmware** (LEDE 19.07.8, MaxLinear PRX126), in the router's SFP cage. Management on 192.168.11.1/24, untagged; LuCI over HTTPS |
| Router side | YT92xx switch via swconfig, switch port 4 = SFP, port 5 = CPU (`eth1`) |
| Sodola 10G switch | Works as a transparent bridge (VLAN 832 tagged on both SFP+ ports, QoS remarking off), but **no port mirroring on SFP ports** |

The stick clones the Livebox's ONT identity (serial, hardware version,
equipment ID, vendor ID, both software versions with **bank B active**).
Registration ID is all zeros, which is correct: Orange never sends `req_passwd`.

## Ports and VLANs

| Port | Role |
|---|---|
| Switch 0-3 | LAN, switch VLAN 1 untagged |
| Switch 4 | SFP cage, forced to 10G |
| `lan5`-`lan8` | 2.5G, separate netdevs in `br-lan`; `lan6`-`lan8` unused |
| `eth2` | 10G to lenora, untagged LAN plus VLAN 10 tagged |
| `eth0` | 10G, in no bridge – the spare |

The YT92xx driver keys on the VLAN **index**: always set `vlan` equal to `vid`.

| UCI section | VID | Ports | Netdev | Use |
|---|---|---|---|---|
| `vlan_lan` | 1 | `0 1 2 3 5t` | `eth1.1` | in `br-lan` |
| `vlan_ont` | 2 | `4 5t` | `eth1.2` | stick management (`ont`, 192.168.11.2/24, no gateway) |
| `vlan_wan` | 832 | `4t 5t` | `eth1.832` | Orange, `wan` / `wan6` |

`eth1.2` has no device section, so its MAC is random per boot. Deliberate – the
stick is reached by IP.

## WAN configuration (values withheld)

`wan_dev` is an 8021q device on `eth1`, VID 832, with the **Livebox's WAN MAC
cloned** and `egress_qos_mapping '0:6 6:6'` – a plain option, not a list. It
marks all WAN traffic CoS 6, which Orange requires for DHCP and accepts for
everything else.

`wan` (DHCPv4):

| UCI option | DHCP option | Value |
|---|---|---|
| `hostname '*'` | 12 | suppressed |
| `vendorid` | 60 | `sagem` |
| `clientid` | 61 | `01` + cloned MAC |
| `defaultreqopts '0'` + `reqopts` | 55 | `1 3 6 15 28 51 58 59 90` |
| `sendopts 0x4d:…` | 77 | `FSVDSL_livebox.Internet.softathome.Livebox3`, RFC 3004 encoded |
| `sendopts 0x5a:…` | 90 | 70-byte auth blob, from `tools/orange-opt90.py` |
| `norelease '1'` | – | stops udhcpc releasing on every interface restart (`-R` absent from the live args) |

`wan6` (DHCPv6, prefix delegation only, `/56` split into `/60`s for lan and iot):

| UCI option | DHCPv6 option | Value |
|---|---|---|
| `reqaddress 'none'` + `reqprefix '56'` | – | no IA_NA |
| `clientid` | 1 | DUID-LL, `0003 0001` + cloned MAC |
| `reqopts '11 17 23 24'` | 6 | matches the Livebox |
| `sendopts '11:…'` | 11 | byte-identical to DHCPv4 option 90 |
| **`userclass`** | **15** | `FSVDSL_livebox.Internet.softathome.Livebox3`, plain string – see below |
| `sendopts '16:…'` | 16 | enterprise 1038 + `sagem` |
| `norelease '1'`, `noclientfqdn '1'` | – | |
| **`reqprefix '56:1'`** | 25 | IA_PD IAID pinned to 1 – see below |

### The IAID trap

Orange binds the delegated prefix to the DUID **and** the IA_PD IAID. The
21.02 odhcp6c always sent IAID 1; from OpenWrt 25.12 (GL 4.11) netifd derives
it from the interface name (`54c55eeb` for `wan6`) unless `reqprefix` carries
one. After that upgrade Orange answered with DNS servers but **no prefix** –
the LAN had only its ULA, and both WireGuard tunnels, whose endpoints are
IPv6, stayed down. `reqprefix '56:1'` brought back the same /56.

The option 90 / 11 blob is MD5 of a random byte, the password and a random
salt, wrapped in fixed TLVs with the `fti/` login. `tools/orange-opt90.py`
builds it from `ORANGE_LOGIN` and `ORANGE_PASSWORD` in the environment.

### The option 15 trap

Passing the user class through `sendopts` as hex **silently produces a
malformed option**, and Orange ignores the SOLICIT – no ADVERTISE, nothing.
`odhcp6c` knows option 15 as a string type, so it sends the hex as literal
ASCII; options 11 and 16 are unknown to it and decode correctly. Use netifd's
`userclass` option, which builds the length prefix itself, and keep `15:` out of
`sendopts`.

**Edit the WAN through `uci` only.** Saving on the GL.iNet UI's Internet page
rewrites `/etc/config/network`.

## Diagnosing the PON

The readings below are collected every minute by `router-metrics/` and graphed
on the **Router and ONT** dashboard in Grafana, with alerts on PLOAM state,
receive power and temperature – start there for history.

**Check the PON before the router.** `eth1.832` RX at exactly 0 bytes means
there is no data path; the switch port reads `link:up 10gbase` regardless,
because the YT92xx forces the 10G path.

```sh
ssh -J root@gw root@192.168.11.1
pon psg    # ploam state: 51 = O5.1 operational, 23 = O2.3 serial-number state
pon gsg    # onu_id, auth_status, fec_status
pon pdcg   # DS counters: assign_onu_id, ranging_time, deact_onu
pon pucg   # US counters: ser_no, reg
pon osg /sys/class/pon_mbox/pon_mbox0/device/eeprom50 \
        /sys/class/pon_mbox/pon_mbox0/device/eeprom51   # optics
```

`osg` scaling: rx/tx power 0.002 dBm per LSB, temperature 1/256 °C, voltage
100 µV per LSB. Bias scaling is unconfirmed.

| Reading | Healthy | Livebox (23 Sep) |
|---|---|---|
| PLOAM state | 51 | O5_Operation |
| FEC ds / us | both locked | – |
| Rx power | −19.3 dBm | −20.27 dBm |
| Tx power | 7.25 dBm | 5.93 dBm |
| Temperature | 44.6 °C idle, ~60 °C loaded | 56 °C |

**Signature of a marginal upstream:** the OLT assigns an ONU-ID, never sends
Ranging_Time (`ranging_time` stays 0), then deactivates – looping every few
minutes, `ser_no` climbing. On 7 October that was a half-seated fibre costing
~3.8 dB (Rx −23.1 dBm); reseating fixed it. The alarm window is −29 to −7 dBm,
so **−23 dBm raises no alarm yet already breaks ranging**. Clean with an SC
one-click cleaner or 99%+ IPA and lint-free wipes, not 70% IPA and cotton.

It was not thermal, not a DHCP or BNG lockout (nothing matters below O5), and
not the stick's management dying.

## A dead session behind a live interface

**The worst WAN failure here is the one where everything reports healthy.** A
PON re-registration can leave the Orange session dead one way while netifd
still holds a valid lease, and nothing in the router's own view says so.

This happened on **23 October 2026**, 15:46 to 17:15 – 88 minutes, ended by a
reboot. What the lab recorded:

| Signal | During the outage |
|---|---|
| `homelab_ont_lods_events_total` | 3 → 4 at ~15:47 – one loss of downstream sync |
| PLOAM state | 51 → 11 → 51, back inside a minute; `ploam_state_seconds` reset |
| Rx power | −19.3 dBm throughout, unchanged |
| `wan` ifstatus | `up: true`, address and default route still installed |
| `homelab_router_ipv6_prefix_delegated` | 1 – the /56 was still configured |
| **WAN RX bytes** | **exactly 0 for 75 minutes** |
| WAN TX bytes | 450–550 B/s, the router's own retries |
| `udhcpc` | **not one line between 13:53 and 17:13** |

The ONT recovered on its own and the line was fine from 15:48. The *session*
was not, and the router never found out.

**Why it cannot notice.** `eth1.832` never loses carrier – the YT92xx forces
the 10G path on the SFP port whatever the PON is doing, which is the same fact
that makes "`link:up 10gbase` proves nothing" true above. No carrier loss means
no `ifdown`, which means udhcpc is never prodded into rebinding, and the lease
had 2.5 days left to run. So the router sat on an address the BNG had stopped
honouring and routed into a black hole.

**Only a fresh DHCP exchange recovers it.** After the reboot:

```
17:13:55 udhcpc: broadcasting discover
17:14:23 udhcpc: lease of 92.150.126.102 obtained from 80.15.225.105, lease time 259200
```

The *same* address, 28 seconds after asking. Swapping the Livebox in first
proved nothing about the Livebox: plugging in any device forces that exchange.
A reboot of this router does the same, and so does `ifup wan`, far more cheaply.

**GL's own tracker knew.** `kmwan` pings 1.1.1.1, 8.8.8.8 and both OpenDNS
addresses with `track_mode=force`, and logged `interface wan offline` at
**15:45:13** – two minutes before the ONT logged the LODS that caused it. On a
single-WAN box it has nothing to fail over to, so it logged the line, cycled
the Wi-Fi and the WireGuard tunnels every two minutes for an hour and a half,
and never touched the WAN. That event is now the early trigger for
`wan-watchdog/`, which probes out of the WAN device and runs `ifup` – see that
directory. It would have ended this in about three minutes.

**If you are in it,** the one-line fix is `ifup wan; ifup wan6` on the router.
To confirm the diagnosis rather than guess, these are the three readings that
separate it from a line that is genuinely down:

```sh
ifstatus wan | jsonfilter -e '@.up' -e '@["ipv4-address"][0].address'  # up, with an address
ssh -J root@gw root@192.168.11.1 pon psg                      # ploam state 51
logread | grep udhcpc | tail                                           # silent = never rebound
```

A live WAN with zero RX bytes is the signature, and `wan-receiving-nothing` in
`grafana/` alerts on exactly that. `ont-downstream-sync-lost` catches the LODS
that precedes it, which the `for: 2m` on "ONT not operational" is too slow to
see.

## Tooling traps on this hardware

- **Verify sent options on the wire** with `tcpdump -XX`, not by reading `uci`.
- **Capture on `eth1`, not the VLAN subinterface**, with `-e` to see the tag
  and PCP. Egress frames show only with **no capture filter**, because the tag
  is inserted by hardware after the filter runs.
- **udhcpc bypasses nftables** (raw sockets), hence the blanket `0:6` egress map
  rather than a `meta priority` rule.
- **Stacked VLANs fail inbound.** `eth1.2.832` sends but never receives; 832
  must exist in the switch, tagged on ports 4 and 5.
- **`busybox nc -z` lies** – it reports every port closed. Use `curl`.
- **`tcpdump -w` buffers**, so a 0-byte pcap usually means unflushed. Use `-l`
  with text output. `and inbound` is unsupported and fails silently.
- **`nohup` does not exist** on the router: `nohup cmd & echo ok` prints `ok`
  and never runs `cmd`.
- The boot-time `Failed to send RS (Address not available)` is a benign DAD race.
- Reach the stick's UI without routes: `ssh -L 8443:192.168.11.1:443 root@gw`.

## IoT Wi-Fi bridging fault

As of 7 October, **any `br-iot` port other than the bridge itself failed to
reach a Wi-Fi station on `ra3`** (ARP never resolves), while the same
arrangement on `br-lan` works. Ruled out: AP isolation (`NoForwarding` is
1-based per `vifidx`; `ra3` is token 4 = `0`), port type, firewall
(`bridge-nf-call-iptables=0`), bridge flags, HNAT and WHNAT offload, `wds`,
and GL's `iot='1'` flag (UI metadata only). The IoT SSIDs were left disabled.

The diagnostic not yet run: point the IoT SSID at `br-lan` and ping a station
from a wired host – that separates a `br-iot` fault from an `ra3`/band 0 one.
If IoT Wi-Fi is revived, the simplest workaround is giving `br-iot` a real
untagged port (`lan6`-`lan8` or `eth0`), reproducing the `br-lan` arrangement.

## Open items

1. Livebox reference capture (options 55/60/61/90, PCP), low priority now both
   stacks work.
2. Stale `secondwan`/`secondwan6` references in the firewall zone and
   `lan.ip6class` – harmless.
3. `glfan` starts the fan only at 70 °C; the stick runs ~60 °C under load.
   Deferred by choice.
4. `avahi` `allow-interfaces=br-lan,br-iot` – `br-iot` is redundant while IoT
   Wi-Fi is off.
