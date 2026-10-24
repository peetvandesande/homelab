# router

**GL.iNet GL-BE14000 running OpenWrt, 192.168.8.1.** Documentation only — there
is no configuration here to deploy.

## This directory holds no config, deliberately

Every other top-level directory mirrors a container filesystem and has a
`deploy.sh` that pushes it. This one does not, and must not grow one.

The router's configuration lives in `uci` on the device, written by the GL.iNet
web UI. A mirror in this repo would be a second source of truth for something a
UI also edits, and it would lose every time: the UI writes `uci` directly, so
the mirror goes stale the moment anyone touches a setting. The same reasoning is
already applied to DHCP reservations, which the top-level `CLAUDE.md` says live
on the router and not here.

What this directory *is* for is the part `uci show` cannot tell you — why a
setting is the way it is, which settings other things in the lab depend on, and
which ones will silently break something if changed.

**A previous `router/` was removed in October 2026** (`a56cb93`). That was not a
decision against documenting the router: the directory contained a status dump
from the Orange Livebox, a device that had already left the lab. Dead content,
removed for being dead. This is different in kind — current, and about
dependencies rather than a snapshot.

`README.md` has the reference detail: networks, the routing-rule priority map,
how the VPN policy routing works, and the two pieces of router-side state the
DNS stack needs. `ORANGE.md` covers the WAN: the XGS-PON stick, the DHCP options
Orange requires, and how to diagnose the PON. `tools/` holds one helper for it,
not config.

## What depends on the router

Three things in this repo break if the router changes underneath them, and none
of them is obvious from the router's own UI.

1. **The lab's DNS filtering depends on `dhcp.lan.dhcp_option` being
   `6,192.168.8.50`.** Hand out anything else and every client resolves around
   Themis, unfiltered. It is `6,192.168.8.50` since 11 October 2026; an earlier
   attempt was reverted on 9 October — see `dns/CLAUDE.md`.

2. **Domain-based VPN routing depends on the router resolving those names.**
   Policy routing matches on destination IP, and the only thing that fills those
   ipsets is the router's own dnsmasq, from the answers it returns. Since clients
   use Themis, Themis shunts exactly the policy domains back to the tunnel's
   dnsmasq instance so the sets keep filling. That is `dns/CLAUDE.md`
   invariant 11, and it is the reason the two systems are coupled at all.

3. **`vpn-domain-sync` on Themis reads the policy off the router hourly**, over
   SSH with a key restricted to one read-only command. Both the command and the
   key authorisation live on the router and are not in this repo, so a firmware
   upgrade can remove them. `README.md` has both to paste back.

## Invariants — changing any of these breaks the lab

1. **Two settings must stay off.** Both would undo the DNS architecture:

   - **`noresolv` plus `server=192.168.8.50` on the main dnsmasq.** Themis
     forwards the VPN policy domains *to* the router, so pointing the router's
     upstream back at Themis is a resolution loop.
   - **The force-DNS redirect** ("override DNS settings of all clients"). The
     `dns_redirect` chain is empty today. Filling it would hijack clients'
     queries to `.50` straight back to the router, which is both a loop and a
     bypass of everything Themis does.

2. **`dhcp.dnsinfra` stays at `6,192.168.8.1`.** The tag covers themis, delphi
   and pythia. It is the same value as the LAN-wide option *was*, which makes it
   look redundant — it is not. Delphi is Themis's backend, so pointing it at
   Themis is a loop, and it could not resolve at boot. The tagged option wins
   because it is more specific.

3. **`server=/home/192.168.8.52` and the matching reverse zone stay.** They let
   the router resolve lab names without going through Themis, which is what
   keeps the router working when the DNS stack is down.

4. **AdGuard Home must stay disabled.** It is installed (`adguardhome.config
   .enabled=0`). Enabling its "handle client requests" adds `adg_redirect` NAT
   rules that take DNS *away* from dnsmasq, which stops the VPN ipsets filling
   altogether. AdGuard supports only legacy `ipset`, not `nftset`, and the only
   workaround is an unofficial sync script. The lab's own filtering replaces what
   it would have done anyway.

5. **The routing-policy domain lists are the source of truth for the shunt.**
   `/etc/domain_mac_list/<set>` is written by the web UI. Themis mirrors it, not
   the other way round. Edit the policy in the UI; the hourly sync follows.

6. **Site-to-site policy rules sit at priority 19000, outside GL's bands.**
   GL owns 10000 and 20000. Anything in (9920, 32766) works; 19000 was chosen to
   avoid sharing a band GL's own scripts rewrite. The lower bound matters as much
   as the upper: staying above `9920 iif br-lan blackhole` and the 6000 `fwmark`
   rules is what keeps LAN traffic under the VPN policy rather than these.

7. **`ip4table`/`ip6table` on a tunnel interface beats a per-route `table`
   option.** A `config route6` with `table 'main'` on `wgclient1` lands in table
   1001, not main. This is not obvious and cost a debugging session: "force the
   route into main" is not achievable that way. Use a policy rule pointing at the
   table that already holds the route.

8. **`/usr/bin/rtp2.sh` rebuilds table 9910 by copying `main`** (`VPN_DIRECT_TABLE
   =9910`). So a route in `main` appears in 9910 shortly afterwards, and a route
   that exists *only* in 9910 or main and not in `uci` was added by hand at
   runtime and will not survive a reboot. Check `proto`: netifd routes say
   `proto static`, hand-added ones say nothing at all.

9. **`firewall.tcp_dns_leak_drop` stays `enabled '0'`.** GL created it under
   fw3 as a drop of dnsmasq's (uid 453) unmarked TCP, the uid match living in
   the iptables-only `extra` option. Upgrading to 4.11 (OpenWrt 25.12, fw4)
   with Keep Settings carried the rule over and fw4 ignored `extra`, so it
   dropped **every** new TCP connection the router itself opened – HTTPS,
   firmware checks, log shipping – while forwarded traffic, DNS, WireGuard and
   SSH in all kept working. On fw4 GL writes the narrow version as
   `/usr/share/nftables.d/ruleset-post/tcp_dns_leak_drop.nft` instead (the
   `skuid 453` line at the top of `inet fw4 output`), so nothing is lost. A
   GL script may re-enable the legacy rule; after any upgrade or VPN change,
   check `wget -O /dev/null https://1.1.1.1/` from the router fails only on
   the certificate, not with "Operation not permitted".

10. **Outgoing DNS that is not Themis is rejected, and two MACs are exempt.**
    The `dns_egress_*` firewall sections reject :53 and :853 from every LAN
    zone and :443 to the `doh_resolvers4/6` sets, so nothing resolves around
    Themis — `README.md` "Outgoing DNS" has the shape. The part that bites:
    the `lan` :53 rule exempts **delphi and hermes by MAC**, because both
    recurse to the outside themselves. Rebuild either with a new MAC and all
    recursion (delphi) or all mail delivery lookups (hermes) stops, with
    nothing more than `Reject-Do53-lan` lines in the router's log to say why.
    Update `firewall.dns_egress_lan_53.src_mac` in the same change as the
    container. Keep the target `REJECT`: with `DROP`, clients wait out a
    timeout per query instead of falling back at once. The resolver sets must
    stay :443-only — the blackbox `internet` probe on .53 pings 1.1.1.1 and
    8.8.8.8, and an all-ports block would make it report the internet down.

11. **Never run `apk upgrade` on this device.** `/etc/apk/repositories.d/
    distfeeds.list` points at GL's **v25.12.5** feeds, while the installed
    firmware is 4.11.0 / **25.12-SNAPSHOT r32295+914**. The feeds are not built
    for the firmware, and the hostapd packages are the ones that matter: GL pins
    `wpad-openssl`, `hostapd-common`, `hostapd-utils` and `wpa-cli` at
    **2022.07.29~b704dc72-r1**, patched for the MediaTek `mt_wifi` vendor
    driver. The feed carries plain upstream **2025.08.26~ca266cc2-r1** and
    nothing MTK-shaped – `apk list "wpad*"` offers no vendor variant – so an
    upgrade silently takes the lab's wireless apart.

    It is not only the 2.3 MB binary being swapped for a 1.9 MB one. The
    upgrade **deletes GL's whole hostapd integration**: all twenty
    `/etc/wpad/template/hostapd_*.conf` band-and-encryption templates,
    `/usr/bin/hostapd_conf_generate.sh`, `/lib/netifd/hostapd.sh` (50 KB of it),
    and GL's `/etc/init.d/wpad`, which reads `/etc/config/wpad`. The generic
    upstream init script replaces it.

    **The damage only shows on the next reboot.** The running hostapd keeps
    serving from configs already generated, so wifi looks fine for as long as
    the box stays up – here, two days. After the reboot the radios still beacon,
    because the driver does that, and SAE even reaches the driver, so "the wifi
    is up" is not evidence. What fails is key derivation: `alg=3` commit and
    confirm complete, then `wappd: ptk size <= 0` and `association error.
    StatusCode: 15`, per client, forever.

    To recover without reflashing, delete the overlay's copies so the squashfs
    originals show through again – **in `/overlay/upper`, not through `/`**,
    where `rm` would write a fresh whiteout instead:

    ```sh
    for p in etc/capabilities/wpad.json etc/init.d/wpad etc/rc.button/wps \
             etc/wpad lib/netifd/dhcp-get-server.sh lib/netifd/hostapd.sh \
             usr/bin/hostapd_conf_generate.sh usr/share/acl.d/wpad_acl.json \
             usr/sbin/hostapd usr/sbin/hostapd-radius usr/sbin/hostapd_cli \
             usr/sbin/wpa_cli usr/sbin/wpa_supplicant usr/sbin/wpad; do
      rm -rf "/overlay/upper/$p"
    done
    sync; reboot
    ```

    Keep `/etc/config/wpad` – it is live config, and the overlay copy is the
    real one. The reboot is not optional: overlayfs caches the negative
    dentries. Afterwards `/usr/sbin/wpad` is 2292663 bytes again, and
    `logread | grep -c "pairwise key handshake completed"` climbs.

    `apk`'s database still claims 2025.08.26 is installed, which is harmless and
    mildly protective – an `apk upgrade` now sees nothing to do – but `apk fix`
    would undo the repair. Done on 23 October 2026; the removed files and the
    pre-change `installed` database are on the device in
    `/root/apk-upgrade-rollback-2026-10-23/`. The same upgrade also pulled
    `curl`, `libcurl4`, `ubus`/`ubusd`, `libubus`, `libid3tag`, `netifyd` and a
    full `luci` forward, all left in place and none of them implicated. A
    firmware reflash with Keep Settings is the way to get back to one coherent
    package set when that is worth a maintenance window.

12. **`dhcp.lan.ra_dns` and `dhcp.lan.dns` are one setting in two halves.**
    The RA advertises Themis's ULA as the recursive DNS server, which is what
    puts IPv6 clients behind the same filtering as the DHCPv4 option
    `6,192.168.8.50`. Set `ra_dns='1'` and leave `dhcp.lan.dns` empty and
    odhcpd advertises **the router itself** instead - every IPv6-capable client
    then resolves at the router, around Themis, and nothing looks broken. If
    Themis is ever renumbered or rebuilt with a new MAC its ULA changes, and
    this list has to change with it; the symptom is IPv6 DNS timing out while
    IPv4 still works, because the egress rules reject the fallback. Setting
    `ra_dns` back to `0` is the safe direction: clients fall back to the
    DHCPv4 option, which is Themis anyway. `README.md` "Themis is advertised
    over IPv6 too".

## Backups

The device keeps `/etc/config/<name>.bak-<date>-<reason>` files from previous
changes — `dhcp.bak-2026-10-09-dns`, `network.bak-2026-10-11-ipv6-s2s` and so
on. They are the only record of what a setting used to be, since this repo
carries no mirror. Keep making them before a change, and keep the reason in the
filename.
