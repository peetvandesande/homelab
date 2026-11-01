# appletv-uk

A switch in Home Assistant, **Apple TV UK**, that moves the living-room Apple
TV's whole internet connection between France (the home line) and the UK
(jennie, over the router's `wgclient2`). The router's `UK` policy already sends
BBC domains via jennie for every device; this is for everything else on the
one device that needs it.

```
router/usr/local/bin/appletv-uk  on | off | status, on the router
ha/command_line.yaml             the switch, written to HA's /config
scripts/deploy.sh                the script, HA's key, its authorisation, the switch
scripts/verify.sh                read-only end-to-end check
```

## How it works

```
HA switch --ssh, key forced to appletv-uk--> router: uci route_policy.appletv_uk.enabled, rtp2.sh
```

- **`route_policy.appletv_uk`** is a GL device rule: `from_type='ipset'`,
  `from='src_mac6612'`, `from_mac` the Apple TV, no destination, via
  `wgclient2`. It shows in the GL UI beside `UK` and can be toggled there too.
  GL adds its own fallback beneath it: if the tunnel is down, the Apple TV
  goes out of the home line rather than dropping.
- **The toggle runs `rtp2.sh not_reload_network`**, which rebuilds GL's
  rules and marks without reloading the network, so the tunnels stay up. It
  takes about 25 seconds. Then it drops the Apple TV's tracked connections,
  because a connection keeps the route it started on.
- **HA's key** is `/config/.ssh/appletv_uk`, generated inside the core
  container by `deploy.sh` and never copied out. It is authorised on the
  router with `command="/usr/local/bin/appletv-uk"` and no forwarding or pty,
  comment `appletv-uk@homeassistant`, so it can flip this switch and nothing
  else. It is in HA's backups, like the rest of `/config`.

## Not created by deploy.sh

Both live in `uci` on the router; `router/CLAUDE.md` explains why this repo
holds no copy. Backups from 1 November 2026 are
`/etc/config/{dhcp,route_policy}.bak-2026-11-01-appletv-uk`.

- **The reservation**: `appletv` at **192.168.8.242**, MAC
  `34:fd:6a:26:4c:83` (DHCP name `Living-Room`). The rule matches the MAC, not
  the address, but the device is named in a policy, so it sits in the
  `.240-.254` range with the others.
- **The rule**, which `deploy.sh` refuses to run without:

  ```sh
  uci set route_policy.appletv_uk=rule
  for kv in "name=Apple TV UK" tunnel_id=6612 enabled=0 killswitch=0 \
      via_type=wireguard group_id=6003 peer_id=8042 \
      profiles=/etc/vpn_profiles.d/profile6612 from_type=ipset \
      from=src_mac6612 masq=0 local_access=1 via=wgclient2 \
      options_in_used=1 mark=0x2000; do
    uci set "route_policy.appletv_uk.${kv%%=*}=${kv#*=}"; done
  uci add_list route_policy.appletv_uk.from_mac=34:FD:6A:26:4C:83
  cp /etc/vpn_profiles.d/profile6611 /etc/vpn_profiles.d/profile6612
  uci commit route_policy
  ```

  `group_id`, `peer_id` and the profile are copied from the `UK` rule, so they
  follow jennie's peer. If that peer is ever recreated in the UI, both rules
  need the new ids.

## Invariants

1. **Themis's `vpn-domain-sync` ignores this rule**, because it reads only
   rules with `to_type='ipset'`. Give this one a destination list and it
   becomes part of the DNS shunt.
2. **DNS stays French.** The Apple TV still resolves through Themis, so a
   CDN may hand back a French edge that is then reached via the UK. Apps that
   go by the exit address do not mind. One that does gets its domains added
   to the `UK` policy, which resolves via jennie (`dns/CLAUDE.md`
   invariant 11).
3. **App availability follows the Apple ID's country, not the network.** UK
   apps come from a UK Apple ID set as the Apple TV's App Store account.
