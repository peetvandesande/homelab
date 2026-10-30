# WireGuard rollout: task list

Every step of the rollout, in order, from where things stood on 2026-10-16. The design and the reasons behind it are in [README.md](README.md). The detailed notes phases 0–7 were run from ("Task N" below) are [Appendix A](#appendix-a-task-notes-phases-07), and rollback is [Appendix B](#appendix-b-rollback).

ruby and jennie each have a clone of this repo at `~/homelab`. Unless a task says otherwise, run commands **on ruby** from `~/homelab/wireguard`; *on jennie* means the same directory on jennie, and *on home* means the home router's own UI or CLI. `git pull` first.

**Never fill secrets into the clone:** the repo is public, and a filled file there is one `git add` from being pushed. Install the template to its destination and fill it there. Phases 0–7 predate the clones and ran from copies in `~/wg` and `~/wg-jennie`, so their commands say so.

`[x]` = done (phase 0 verified on ruby 2026-10-09; phases 1–7 reported done 2026-10-16; 8.1–8.5 done 2026-10-16, 8.4 checked on jennie), `[ ]` = to do. Phases 1–3 don't disturb anything running; phase 4 is the only one with downtime.

***

## Phase 0: Done

- [x] Back up `/etc/wireguard` → `/etc/wireguard.bak-2026-10-08`
- [x] Generate ruby's wg1/wg2 keys, the ruby–jennie PSK (`jennie.psk`) and the home–jennie PSK (`home-jennie.psk`)
- [x] Generate jennie's wg2 key on jennie (public key `+0MxQ46p…`)
- [x] Fill ruby's wg0 key and the client/home PSKs (`fill-secrets.py`, Task 1a)
- [x] Install ruby's new `/etc/nftables.conf` (Task 2b)
- [x] Install and enable `wg-docker-user.service` (Task 2c)
- [x] Install ruby's `82-wireguard-wg2.yaml`; wg2 is up with the via-jennie table 200 and its rules
- [x] Publish the WordPress container on loopback only (`/opt/wordpress-sogode/docker-compose.yml`)
- [x] jennie: dummy0 and wg2 up. ruby reaches `172.31.1.6`, `fd33:5692:1834:ff02::2`, `192.168.254.2` and `fd33:5692:1834:254::2` (checked 2026-10-09).
- [x] jennie: wg3 up (reported from home)
- [x] home: wg3 (`wgclient2`) configured and up, with main-table routes to jennie, table 1002 with GL route policy `UK` (BBC domains and jennie's dummy), and IPv6 masquerade in `/etc/firewall.user`
- [x] home: global ULA `fd33:5692:1834::/48`; LAN `/64`s lan `1000::`, iot `1001::`, guest `1002::` (disabled); iot's stray `/60` fixed

***

## Phase 1: ruby preparation (no impact)

- [x] **1.1 Forwarding owned by networkd** (Task 2a). IPv6 forwarding currently depends on Docker.
  ```bash
  sudo install -D -m 644 ruby/networkd-forwarding.conf /etc/systemd/networkd.conf.d/forwarding.conf
  sudo systemctl restart systemd-networkd
  cat /proc/sys/net/ipv{4,6}/conf/all/forwarding          # 1, 1
  ```
- [x] **1.2 Renumber ruby's dummy IPv6** `fd00::1/2` → `fd33:5692:1834:254::254/253` (Task 2e)
  ```bash
  sudo diff /etc/netplan/70-dummy-interfaces.yaml ruby/70-dummy-interfaces.yaml   # only the IPv6 lines differ
  sudo cp -a /etc/netplan/70-dummy-interfaces.yaml /etc/netplan/70-dummy-interfaces.yaml.bak-$(date +%F)
  sudo install -m 600 ruby/70-dummy-interfaces.yaml /etc/netplan/
  sudo netplan generate && sudo networkctl reload && sudo networkctl reconfigure dummy0 dummy1
  ip -br addr show dummy0; ip -br addr show dummy1      # fd33:…:254::254 / ::253, no fd00::
  ```
- [x] **1.3 (cosmetic) Refresh the firewall comments** renamed from home-inet to home
  ```bash
  sudo install -m 755 ruby/nftables.conf /etc/nftables.conf
  sudo nft -c -f /etc/nftables.conf && sudo systemctl reload nftables   # reload, NOT restart
  ```

***

## Phase 2: jennie, firewall and forwarding

wg2, wg3 and dummy0 are already up on jennie. What's left is forwarding and the firewall, and **the internet exit depends on them**: until 2.3 and 2.4 are done, traffic the home router sends to jennie for BBC (and client IPv6 sent via ruby's table 200) has no NAT on jennie and goes nowhere.

- [x] **2.1 Checks** (*on jennie*, Task 2d)
  ```bash
  systemctl --version | head -1                  # >= 256
  sudo ss -tulpn | grep -vE '127\.0\.0\.|\[::1\]'  # public services to add under "Public services" in nftables.conf
  systemctl is-active docker                     # expected inactive; if active, see Task 2d first
  ip -br link show type dummy                    # dummy0 free? otherwise rename it in 70-dummy0.yaml
  ```
- [x] **2.2 Copy jennie's files** (*on ruby*). If jennie's wg2/wg3 were set up some other way, compare them with `jennie/*.yaml`, especially wg2's allowed IPs and routes for ruby's renumbered dummies.
  ```bash
  scp -r ~/wg/jennie jennie:wg-jennie
  ```
- [x] **2.3 Forwarding** (*on jennie*)
  ```bash
  sudo install -D -m 644 networkd-forwarding.conf /etc/systemd/networkd.conf.d/forwarding.conf
  sudo systemctl restart systemd-networkd
  cat /proc/sys/net/ipv{4,6}/conf/all/forwarding; ip -6 route show default
  ```
- [x] **2.4 Firewall with a dead-man switch** (*on jennie*, Task 2d)
  ```bash
  sudo cp -a /etc/nftables.conf /etc/nftables.conf.bak-$(date +%F) 2>/dev/null
  sudo install -m 755 nftables.conf /etc/nftables.conf && sudo nft -c -f /etc/nftables.conf
  sudo systemd-run --on-active=180 --unit=nft-deadman /usr/sbin/nft delete table inet filter
  sudo nft -f /etc/nftables.conf
  # NEW ssh session to jennie works? then:
  sudo systemctl stop nft-deadman.timer && sudo systemctl enable --now nftables
  ```
- [x] **2.5 dummy0 and wg2** (*on jennie*, Task 3)
  ```bash
  sudo apt install wireguard-tools
  sed -i "s|<jennie wg2 private key>|$(sudo cat /etc/wireguard/jennie.key)|" 82-wireguard-wg2.yaml
  grep -n '<' 70-dummy0.yaml 82-wireguard-wg2.yaml || echo filled
  sudo install -m 600 70-dummy0.yaml 82-wireguard-wg2.yaml /etc/netplan/
  sudo netplan generate && sudo networkctl reload
  ```
- [x] **2.6 Test wg2** (*on ruby*): pings in both families done 2026-10-09. Still to do: the MTU ping, and the ping back to ruby's dummy after 1.2.
  ```bash
  sudo wg show wg2                                      # recent handshake
  ping -c3 172.31.1.6; ping -c3 fd33:5692:1834:ff02::2
  ping -c3 192.168.254.2; ping -c3 fd33:5692:1834:254::2
  ping -M do -c3 -s 1392 172.31.1.6                     # MTU
  ```
  And *on jennie*: `ping -c3 192.168.254.254` and `ping -c3 fd33:5692:1834:254::254` (ruby's renumbered dummy, after 1.2).

***

## Phase 3: jennie ↔ home, wg3

- [x] **3.1 Keys** (Task 4a)
  - *On jennie:* `(umask 077; wg genkey | sudo tee /etc/wireguard/wg3.key | wg pubkey)` → give the public key to home
  - *On home:* create a new WireGuard interface `wg3` with its own key → give its public key to jennie
  - *On jennie:* fill `83-wireguard-wg3.yaml` with jennie's wg3 private key and home's wg3 public key
  - *On ruby:* `sed -i "s|<jennie wg3 public key>|PUBKEY|" home/wg3.conf` (reference copy)
- [x] **3.2 Install wg3** (*on jennie*)
  ```bash
  grep -n '<' 83-wireguard-wg3.yaml || echo filled
  sudo install -m 600 83-wireguard-wg3.yaml /etc/netplan/ && sudo netplan generate && sudo networkctl reload
  ```
- [x] **3.3 Configure home's wg3** (*on home*, Task 4c, `home/wg3.conf`): done as `wgclient2`, with GL route policy `UK`
  - address `172.31.1.10/30`, `fd33:5692:1834:ff03::2/64`, MTU 1388
  - peer jennie, PSK from `home-jennie.psk`, endpoint `[2001:41d0:801:2000::180f]:51823`, keepalive 25
  - allowed IPs `0.0.0.0/0, ::/0`, **automatic routes off**
  - routes via wg3: `172.31.1.9/32`, `192.168.254.2/32`, `fd33:5692:1834:ff03::1/128`, `fd33:5692:1834:254::2/128`
  - internet via jennie: a policy table with default routes via wg3, plus rules for the chosen traffic (the laptop, BBC ranges, …)
  - IPv6 masquerade on wg3 egress to `fd33:5692:1834:ff03::2` (no IPv4 NAT)
- [x] **3.3a Narrow the IPv6 masquerade** (*on home*, `/etc/firewall.user`) so VPN (ULA) sources keep their address:
  `ip6tables -t nat -A POSTROUTING -o wgclient2 ! -s fd33:5692:1834::/48 -j MASQUERADE` (replacing the current rule). Then `/etc/init.d/firewall restart`.
- [x] **3.4 Test wg3** (exit tests need 2.3/2.4 first)
  - *On jennie:* `sudo wg show wg3` (recent handshake from home); `ping -c3 172.31.1.10`; `ping -c3 192.168.8.1`; `traceroute -n 192.168.8.1` (one hop, to 192.168.8.1, since the router is the destination); `ping -M do -c3 -s 1360 172.31.1.10`
  - *From the laptop at home:* `curl -4 https://www.bbc.co.uk` exits via jennie. Check on the router before and after with `cat /sys/class/net/wgclient2/statistics/tx_packets` (the count rises). The IPv6 masquerade is tested under 3.3a. `ifconfig.co` isn't in the UK policy, so it correctly shows the home ISP address (the Orange IPv4 and `2a01:cb1c:…`), not jennie's.
- [x] **3.5 `.home` names on jennie** (*on jennie*, Task 4b). Add the `nameservers` block from `83-wireguard-wg3.yaml` to the live, filled `/etc/netplan/83-wireguard-wg3.yaml`; don't reinstall the template over it.
  ```bash
  resolvectl status | head -3                      # jennie must be using systemd-resolved
  dig @192.168.8.52 pythia.home +short             # Pythia reachable over wg3: 192.168.8.52
  sudo netplan generate && grep -H Domains /run/systemd/network/*wg3*.network   # Domains=~home ~8.168.192.in-addr.arpa
  sudo networkctl reload
  resolvectl domain wg3; resolvectl dns wg3        # ~home ~8.168.192.in-addr.arpa; 192.168.8.52
  resolvectl query pythia.home                     # 192.168.8.52, via wg3
  resolvectl query 192.168.8.52                    # pythia.home
  ```

***

## Phase 4: cutover, ruby wg0/wg1 and services (downtime)

Clients drop for a few seconds; home ↔ ruby is down until 4.5. Have 4.1 ready first, and do 4.3–4.4 in one go: Dovecot's current drop-in still refers to wg-quick.

- [x] **4.1 Prepare home's wg1 settings** (*on home*, Task 5a, `home/wg1.conf`)
  - keep the router's key and PSK; peer key → ruby's wg1 `UFJld/qz…` (`wg1.pub`)
  - address `172.31.1.2/30`, `fd33:5692:1834:ff01::2/64` (remove `192.168.204.5`), MTU 1388
  - endpoint `[2001:41d0:305:2100::1:3a0e]:51821`, keepalive 25
  - allowed IPs/routes: `172.31.1.1/32, fd33:5692:1834:ff01::1/128, 192.168.204.0/24, fd33:5692:1834:204::/64, 192.168.254.253/32, 192.168.254.254/32, fd33:5692:1834:254::254/128, fd33:5692:1834:254::253/128`
  - ~~LANs: ULA `/64` per LAN~~ done (Phase 0)
- [x] **4.2 Stage the netplan files** (Task 5b)
  ```bash
  sudo install -m 600 ruby/80-wireguard-wg0.yaml ruby/81-wireguard-wg1.yaml /etc/netplan/
  sudo netplan generate && echo OK
  cd ruby/services && for f in $(cd orig && find etc -type f); do cmp -s "orig/$f" "/$f" && echo "unchanged /$f" || echo "CHANGED /$f"; done; cd ~/wg
  ```
- [x] **4.3 Cut over** (Task 5c)
  ```bash
  sudo systemctl disable --now wg-quick@wg0
  sudo networkctl reload
  networkctl list | grep -E 'wg[0-2]'                  # configured
  ```
- [x] **4.4 Services: IPv6 and VPN-wide DNS, start order** (Task 5e, review `ruby/services/services.diff`)
  ```bash
  cd ~/wg/ruby/services
  sudo install -m 644 etc/systemd/system/dovecot.service.d/dovecot-local-deps.conf /etc/systemd/system/dovecot.service.d/
  sudo install -D -m 644 etc/systemd/system/postfix.service.d/local-deps.conf /etc/systemd/system/postfix.service.d/local-deps.conf
  sudo systemctl daemon-reload
  sudo install -m 644 -o root -g bind etc/bind/named.conf.options etc/bind/named.conf.local /etc/bind/
  sudo named-checkconf && sudo rndc reconfig
  sudo install -m 644 etc/postfix/master.cf /etc/postfix/master.cf
  sudo postfix check && sudo systemctl restart postfix
  sudo install -m 644 etc/dovecot/conf.d/20-managesieve.conf /etc/dovecot/conf.d/
  sudo doveconf -n >/dev/null && sudo systemctl reload dovecot
  ss -lntuH | grep -E '(fd33:5692:1834:204::254|fd33:5692:1834:254::254)\]?:(53|465|587|4190)\b'
  cd ~/wg
  ```
- [x] **4.5 Apply home's wg1 settings** from 4.1 (*on home*)
- [x] **4.6 Check** (Task 5d)
  ```bash
  sudo wg show                                          # wg0 clients back; wg1 handshake from an IPv6 address
  ip route | grep -E 'wg[0-2]'; ip -6 route | grep -E 'wg[0-2]'
  ping -c3 172.31.1.2; ping -c3 192.168.8.1; ping -M do -c3 -s 1360 172.31.1.2
  ```

***

## Phase 5: clients

- [x] **5.1 Update each client** (mba, iphone-peet, mbp; Task 6). Keep keys, PSK and endpoint.
  - `Address = 192.168.204.N/32, fd33:5692:1834:204::N/128`
  - full tunnel: `AllowedIPs = 0.0.0.0/0, ::/0`, or the split-tunnel list in README [Clients on ruby](README.md#clients-on-ruby)
  - DNS: `192.168.204.254` (optionally also `fd33:5692:1834:204::254`)
- [x] **5.2 Choose IPv4 exits.** All clients use ruby by default; to send one via jennie, add `- { from: "192.168.204.N/32", table: 200, priority: 1000 }` to `ruby/82-wireguard-wg2.yaml` (README Day-to-day)
- [x] **5.3 Test from a client**
  ```bash
  ping 192.168.204.254; ping6 fd33:5692:1834:204::254; ping 192.168.254.2; ping 192.168.8.1
  dig @fd33:5692:1834:204::254 mail.peetvandesande.com +short       # 192.168.204.254
  curl -4 https://ifconfig.co      # 46.105.253.72 (or 57.129.180.73 if opted in)
  curl -6 https://ifconfig.co      # 2001:41d0:801:2000::180f (jennie)
  ```

***

## Phase 6: end to end and reboots

- [x] **6.1 Service access from every site** (Task 5e). *On jennie* and *from a home host*: `dig @192.168.204.254 mail.peetvandesande.com +short`, `dig @192.168.204.254 pythia.home +short` (192.168.8.52), `dig @192.168.204.254 -x 192.168.8.52 +short`, `nc -zv 192.168.204.254 587`, `nc -zv 192.168.204.254 4190`, and the same over `fd33:5692:1834:204::254`
- [x] **6.2 Paths** (Task 7). *On jennie:* `traceroute -n 192.168.8.1` goes direct over wg3. *From home:* `traceroute -n 192.168.204.1` goes via ruby, and `traceroute -n 192.168.254.2` via jennie.
- [x] **6.3 Reboot ruby**, then check: `networkctl list`, `sudo wg show`, `ip rule`, `sudo ip6tables -S DOCKER-USER`, `systemctl is-active postfix dovecot named`, and `ss -lnt` for 587/465/4190 on both families
- [x] **6.4 Reboot jennie**, then check: `networkctl list`, `sudo wg show`, `sudo nft list ruleset | head`, `cat /proc/sys/net/ipv{4,6}/conf/all/forwarding`

***

## Phase 7: cleanup

- [x] **7.1 Secrets in `~/wg`:** `shred -u wg1.key wg2.key jennie.psk home-jennie.psk`; shred or lock down the filled YAML/conf files; *on jennie*, `shred -u ~/wg-jennie/*.yaml`
- [x] **7.2** Delete `~/wg/superseded/`
- [x] **7.3** Once rollback is no longer needed: remove `/etc/wireguard/wg0.conf` and `/etc/wireguard.bak-2026-10-08`, and the `.bak-*` files in `/etc/netplan` and `/etc/nftables.conf.bak-*`

***

## Phase 8: clients on jennie (README [Clients on jennie](README.md#clients-on-jennie))

No impact on anything running: wg0 on jennie is a new tunnel, and the routes and rules elsewhere only match the new range. `git -C ~/homelab pull` on jennie and ruby first.

- [x] **8.1 Key and PSKs** (*on jennie*). The template is installed first and filled in `/etc/netplan`, never in the clone. Keep copies of the key and PSKs in `~/projects/homelab-private/wireguard/`.
  ```bash
  cd ~/homelab/wireguard
  (umask 077; wg genkey | sudo tee /etc/wireguard/wg0.key | wg pubkey)     # jennie wg0 public key, for the clients
  for c in mba iphone-peet mbp; do (umask 077; wg genpsk | sudo tee /etc/wireguard/jennie-$c.psk >/dev/null); done
  F=/etc/netplan/80-wireguard-wg0.yaml
  sudo install -m 600 -o root -g root jennie/80-wireguard-wg0.yaml $F
  sudo sed -i "s|<jennie wg0 private key>|$(sudo cat /etc/wireguard/wg0.key)|" $F
  for c in mba iphone-peet mbp; do sudo sed -i "s|<psk jennie-$c>|$(sudo cat /etc/wireguard/jennie-$c.psk)|" $F; done
  sudo grep -n '<' $F || echo filled
  git status --short                                                        # clean: nothing filled in the clone
  ```
- [x] **8.2 Firewall** (*on jennie*): opens UDP 51820 on both families and adds wg0 to the VPN.
  ```bash
  sudo cp /etc/nftables.conf /etc/nftables.conf.bak-$(date +%F)
  sudo install -m 644 jennie/nftables.conf /etc/nftables.conf
  sudo nft -c -f /etc/nftables.conf && sudo systemctl reload nftables
  ```
- [x] **8.3 Install wg0** (*on jennie*)
  ```bash
  sudo netplan generate && sudo networkctl reload                # the file was installed and filled in 8.1
  sudo wg show wg0; ip -br addr show wg0       # 192.168.205.254/24, fd33:5692:1834:205::254/64
  ```
- [x] **8.4 BIND** (*on jennie*)
  ```bash
  sudo apt install bind9
  sudo install -m 644 -o root -g bind jennie/services/etc/bind/named.conf.options jennie/services/etc/bind/named.conf.local /etc/bind/
  sudo install -d -m 755 -o bind -g bind /etc/bind/wireguard
  sudo install -m 644 -o bind -g bind jennie/services/etc/bind/wireguard/* /etc/bind/wireguard/
  sudo named-checkconf -z && sudo systemctl restart named
  sudo ss -lnup 'sport = 53'                                   # 205::254, 254::2, loopback; never 57.129.180.73
  dig @192.168.205.254 mail.peetvandesande.com +short          # 192.168.204.254
  dig @192.168.205.254 pythia.home +short                      # 192.168.8.52
  dig @192.168.205.254 -x 192.168.8.52 +short                  # pythia.home.
  dig @192.168.205.254 -x 192.168.205.1 +short                 # mba.
  dig @192.168.205.254 www.bbc.co.uk +short                    # recursion works
  dig @192.168.205.254 dnssec-failed.org | grep status         # SERVFAIL: validating
  ```
- [x] **8.5 ruby: route back to jennie's clients** (*on ruby*). The live `/etc/netplan/82-wireguard-wg2.yaml` holds the real PSK, so add the two `205` routes from `ruby/82-wireguard-wg2.yaml` to it by hand rather than reinstalling. Then apply live without dropping wg2:
  ```bash
  sudo netplan generate
  sudo ip route add 192.168.205.0/24 dev wg2 && sudo ip -6 route add fd33:5692:1834:205::/64 dev wg2
  ip route get 192.168.205.1; ip -6 route get fd33:5692:1834:205::1     # both dev wg2
  ```
  ruby's DNS ACL needs `192.168.205.0/24` in its `acl "vpn"` too. The repo's `named.conf.local` has had it since 2026-10-15; check the live one with `grep 205 /etc/bind/named.conf.local`, and if it's missing add the line and `sudo named-checkconf && sudo rndc reconfig`.
- [x] **8.6 home: policy rules into wgclient2** (*on home*, `router/README.md`, "Site-to-site: the rules at 19000")
  ```sh
  cp /etc/config/network /etc/config/network.bak-$(date +%F)-jennie-clients
  uci set network.s2s_wgclient2_205=rule
  uci set network.s2s_wgclient2_205.dest='192.168.205.0/24'
  uci set network.s2s_wgclient2_205.lookup='1002'
  uci set network.s2s_wgclient2_205.priority='19000'
  uci set network.s2s_wgclient2_205_6=rule6
  uci set network.s2s_wgclient2_205_6.dest='fd33:5692:1834:205::/64'
  uci set network.s2s_wgclient2_205_6.lookup='1002'
  uci set network.s2s_wgclient2_205_6.priority='19000'
  uci commit network && /etc/init.d/network reload
  ip rule | grep 19000; ip -6 rule | grep 19000                   # five each
  ip route get 192.168.205.1 from 192.168.8.1                      # dev wgclient2
  ```
- [x] **8.7 Clients**: add the second tunnel on mba, mbp and iphone-peet (README [Client config](README.md#client-config)), with jennie's wg0 public key from 8.1 and each device's PSK. Then, with only the jennie tunnel up:
  ```bash
  ping 192.168.205.254 && ping6 fd33:5692:1834:205::254   # jennie
  ping 192.168.8.52                                        # home, via wg3
  ping 192.168.204.254                                     # ruby, via wg2
  ping6 fd33:5692:1834:204::254                            # ruby over IPv6: mail's AAAA (follow-up below) makes clients prefer it
  dig pythia.home +short                                   # 192.168.8.52, from jennie's BIND
  curl -4 https://ifconfig.co                              # 57.129.180.73
  curl -6 https://ifconfig.co                              # 2001:41d0:801:2000::180f
  ```

***

## Follow-ups (optional, outside the rollout)

- [x] **Clients cannot reach the Proxmox lab SDN (`192.168.32.0/21`).** Found 2026-10-20 from mbp on wg0, fixed and deployed on ruby and jennie the same day. The change is in `ruby/81-wireguard-wg1.yaml`, `jennie/83-wireguard-wg3.yaml` and both `nftables.conf`.
  - **Cause:** the lab SDN is a second prefix behind home and is not part of `192.168.8.0/21`, so it was in neither wg1's peer allowed IPs nor its route list. Client packets for it matched ruby's default route and were SNATed to `46.105.253.72`: `traceroute 192.168.32.11` from mbp went mbp → `192.168.204.254` → an OVH private address and no further. Names resolved throughout (`os-1.openstack.home` → `192.168.32.11` from ruby's `home` static-stub), which is what made it look like a routing-only failure. Verified the same day that the lab is up and the return path is fine: from lenora, `192.168.32.11`, `192.168.33.10` and `192.168.204.4` all ping, and the router marks `192.168.204.0/24` into table 1001 from `br-lan` via `dst_net4399_sta`.
  - *On ruby*:
    ```bash
    cd ~/homelab && git pull && cd wireguard
    diff /etc/netplan/81-wireguard-wg1.yaml ruby/81-wireguard-wg1.yaml   # allowed-ips and routes only
    sudo install -m 600 -o root -g root ruby/81-wireguard-wg1.yaml /etc/netplan/
    sudo sed -i 's|<ruby wg1 private key>|'"$(sudo cat /etc/wireguard/wg1.key)"'|' /etc/netplan/81-wireguard-wg1.yaml
    sudo sed -i 's|<psk home>|'"$(sudo cat /etc/wireguard/psk-home)"'|' /etc/netplan/81-wireguard-wg1.yaml
    sudo netplan generate && sudo netplan apply
    sudo wg show wg1 allowed-ips          # 192.168.32.0/21 present
    ip route get 192.168.32.11            # dev wg1
    sudo nft -c -f ruby/nftables.conf && sudo install -m 644 ruby/nftables.conf /etc/ && sudo systemctl reload nftables
    ```
    (the key/PSK names are whatever `homelab-private/wireguard` uses; fill them in the installed file, never in the clone)
  - Then the same on *jennie* for `83-wireguard-wg3.yaml` and `jennie/nftables.conf`, and from mbp: `ping 192.168.32.11`, `ssh os-1`.
  - **Verified on ruby's wg0 2026-10-20:** `ping 192.168.32.11` and `192.168.33.10`, `ssh os-1`, and `traceroute` staying inside the tunnel instead of reaching an OVH address. jennie's half was verified on its own wg0.
  - **Reverse zones, done in the same change:** `static-stub`s for `32`–`39.168.192.in-addr.arpa` in ruby's `wireguard` view, so `dig @192.168.204.254 -x 192.168.32.11` answers `os-1.openstack.home.` where `disable-empty-zone "168.192.in-addr.arpa"` used to send it out to AS112. jennie has them too, in its own follow-up below.

- [ ] **LAN clients could not reach ruby over IPv6 – Wi-Fi, not routing.** Found and diagnosed 2026-10-16, *on home (router)*. Keep the AAAA records `dns/` added in e174ea4.
  - **Cause:** the laptop (mbp, on the 6 GHz MLO link `rax2`) had stopped receiving group-addressed frames from the AP. The router's NS for its ULA went out to the right solicited-node group and was never answered; ARP to its IPv4 failed the same way, and so did NS for its link-local and GUA. Unicast worked, so anything the laptop started worked, and only replies the router had to resolve first – here, return traffic from wgclient1 – died. Routing, the NDP proxy, the bridge's MLD snooping and the driver's own snooping were all ruled out. Reconnecting the laptop's Wi-Fi fixed it. Write-up and a check in `router/README.md`, "Wi-Fi: clients that stop hearing multicast".
  - **Verified after reconnecting:** from the laptop, `ping6 fd33:5692:1834:254::254` works and `curl -6 -sI https://ruby.peetvandesande.com/postfixadmin/` returns 302.
  - **Still to do:** confirm on ruby that `/var/log/nginx/ruby.peetvandesande.com-https-access.log` shows an `fd33:5692:1834:1000:` source (needs sudo). Then watch for a recurrence: the root cause is unknown, so this stays open until the laptop has gone a week or so without it. If it comes back, use the check in `router/README.md`, note what the laptop was doing (sleep, roaming between links), and try the laptop on a non-MLO SSID to tell the client from the AP.
- [x] **BIND reverse zone `204.168.192.in-addr.arpa`:** remove the stale PTRs `3 sylvie` and `5 home-inet`, and bump the serial
- [x] **BIND: transit and ULA reverse zones, mail AAAA.** Deployed on ruby and jennie 2026-10-16: `1.31.172.in-addr.arpa`, `4.3.8.1.2.9.6.5.3.3.d.f.ip6.arpa` and `AAAA fd33:5692:1834:204::254` in the split-horizon `mail.peetvandesande.com`. The zone files are shared: one copy, in `jennie/services/etc/bind/wireguard/`, installed on both hosts. They sit beneath BIND's automatic `31.172.in-addr.arpa` and `d.f.ip6.arpa` empty zones, so they add names rather than speed. They are served to VPN sources only; ruby's own daemons resolve in the `internal` view and don't see them.
- [x] **BIND: service-address reverse zones, 205 on ruby.** Deployed on ruby and jennie 2026-10-16. Both hosts disable the `168.192.in-addr.arpa` empty zone so the lab's PTRs reach Pythia, so every other `192.168.x` PTR goes out to AS112. Checked 2026-10-16: `-x 192.168.254.254` is SERVFAIL on both hosts and `-x 192.168.205.1` is SERVFAIL on ruby. Adds `254.168.192.in-addr.arpa` on both, jennie's `205.168.192.in-addr.arpa` on ruby too, and the `254::254`/`::253` PTRs in the ULA zone (serial `2026101602`). The 205 and transit files only changed in their comments. *On ruby*:
  ```bash
  cd ~/homelab/wireguard
  diff /etc/bind/named.conf.local ruby/services/etc/bind/named.conf.local      # only the 205 and 254 zones
  sudo install -m 644 -o bind -g bind jennie/services/etc/bind/wireguard/{205.168.192.in-addr.arpa,254.168.192.in-addr.arpa,4.3.8.1.2.9.6.5.3.3.d.f.ip6.arpa} /etc/bind/wireguard/
  sudo install -m 644 -o root -g bind ruby/services/etc/bind/named.conf.local /etc/bind/
  sudo named-checkconf -z && sudo rndc reconfig && sudo rndc reload 4.3.8.1.2.9.6.5.3.3.d.f.ip6.arpa IN wireguard
  dig @192.168.204.254 -x 192.168.254.254 +short                    # mail.peetvandesande.com.
  dig @192.168.204.254 -x 192.168.254.2 +short                      # jennie.
  dig @192.168.204.254 -x 192.168.205.1 +short                      # mba.
  dig @192.168.204.254 -x fd33:5692:1834:254::254 +short            # mail.peetvandesande.com.
  ```
  Then *on jennie*:
  ```bash
  cd ~/homelab/wireguard
  diff /etc/bind/named.conf.local jennie/services/etc/bind/named.conf.local    # comments and the 254 zone
  sudo install -m 644 -o bind -g bind jennie/services/etc/bind/wireguard/{205.168.192.in-addr.arpa,254.168.192.in-addr.arpa,1.31.172.in-addr.arpa,4.3.8.1.2.9.6.5.3.3.d.f.ip6.arpa} /etc/bind/wireguard/
  sudo install -m 644 -o root -g bind jennie/services/etc/bind/named.conf.local /etc/bind/
  sudo named-checkconf -z && sudo rndc reconfig && sudo rndc reload 4.3.8.1.2.9.6.5.3.3.d.f.ip6.arpa
  ```
  and the same four `dig`s against `@192.168.205.254`. `.253` is named `ruby.` as a placeholder: rename it in both zones if dummy1 has a service name.
- [x] **Postfix:** `wireguard_clients.cidr` isn't referenced. Either wire it into `mua_client_restrictions` (extended to the VPN ranges) or correct the `main.cf` comments that say it's in use. Update `main.cf`'s header, which still describes the VPN as `192.168.204.0/24 (wg0)`.
- [x] **BIND on jennie: the labs' reverse zones.** Deployed 2026-10-20. **The first lookup after `rndc reconfig` can SERVFAIL, and that is the cold cache, not the config:** jennie validates, so a reverse lookup outside the stubbed prefixes has to prime `. → arpa → in-addr.arpa → 192.in-addr.arpa` and reach the AS112 blackhole servers first. Seen once on `-x 192.168.9.1` (SERVFAIL, 764 ms); the same query costs ~70 ms afterwards, and two `/24`s never queried before answered NXDOMAIN in 78 and 71 ms. A SERVFAIL on a warm cache is a different problem. Verified after deploying: `32.11`/`33.10` name the lab from Pythia, `8.21` is `lenora.`, `205.1` and `254.2` come from the local zones, and `9.1`/`10.1`/`11.1`/`13.1` are NXDOMAIN. jennie is single-view, so a client that failed over to it loses the lab's PTRs without these. `32`–`39.168.192.in-addr.arpa` as `static-stub`s, and the same eight names in `validate-except` — jennie validates, unlike ruby (`dnssec-validation no` there), and Pythia's zones are unsigned. The guest, iot and ONT nets are deliberately not stubbed on either host: Pythia holds no reverse zone for them, so a stub turns their NXDOMAIN into a SERVFAIL. *On jennie*:
  ```bash
  cd ~/homelab && git pull && cd wireguard
  diff /etc/bind/named.conf.local   jennie/services/etc/bind/named.conf.local      # the eight lab zones
  diff /etc/bind/named.conf.options jennie/services/etc/bind/named.conf.options    # validate-except
  sudo install -m 644 -o root -g bind jennie/services/etc/bind/named.conf.local /etc/bind/
  sudo install -m 644 -o root -g bind jennie/services/etc/bind/named.conf.options /etc/bind/
  sudo named-checkconf -z && sudo rndc reconfig
  dig @192.168.205.254 -x 192.168.32.11 +short       # a lab host, while a lab is running
  dig @192.168.205.254 -x 192.168.8.21 +short        # lenora., unchanged
  dig @192.168.205.254 -x 192.168.9.1 +short         # nothing, and NXDOMAIN rather than SERVFAIL
  ```
- [ ] **Failover:** with static routing, a wg3 outage cuts jennie off from home. BIRD or FRR (OSPF) over wg1/wg2/wg3 could reroute via ruby.
- [x] **Remove sylvie** wherever else it's referenced (monitoring, password managers, …)
- [x] **Home, `home/wg3.conf`:** fill in `<jennie wg3 public key>` in the reference copy, so it matches the router
- [x] **BIND: reverse zones in ruby's `internal` view.** Written 2026-10-16, extended and deployed 2026-10-20: the five shared reverse zones (204, 205, 254, transit, ULA) declared in the `internal` view too, so Postfix and Dovecot log VPN peers by name, plus a `static-stub` for `8.168.192.in-addr.arpa` there. hermes (192.168.8.57) submits to dummy0 for the domains it routes out, so Postfix logs a client in the home LAN and resolves it in this view, where the automatic `168.192` empty zone answers NXDOMAIN. No `disable-empty-zone` in this view, deliberately: a declared zone beats the empty zone, so the LAN is named while every other 192.168 PTR still gets NXDOMAIN without leaving the host. The lab range stays out — nothing resolving in this view ever sees one of its addresses, since a lab's mail reaches ruby via hermes. Same files, nothing new to install under `/etc/bind/wireguard/`. *On ruby*:
  ```bash
  cd ~/homelab/wireguard
  diff /etc/bind/named.conf.local ruby/services/etc/bind/named.conf.local      # only the six zones in view "internal"
  sudo install -m 644 -o root -g bind ruby/services/etc/bind/named.conf.local /etc/bind/
  sudo named-checkconf -z && sudo rndc reconfig
  dig @127.0.0.1 -x 192.168.205.1 +short                         # mba.
  dig @127.0.0.1 -x 192.168.254.2 +short                         # jennie.
  dig @127.0.0.1 -x fd33:5692:1834:204::1 +short                 # mba.
  dig @192.168.204.254 -x 192.168.205.1 +short                   # mba. (the wireguard view, unchanged)
  dig @127.0.0.1 -x 192.168.8.57 +short                          # hermes.
  dig @127.0.0.1 -x 192.168.32.11 +short                         # nothing: the lab range is not in this view
  ```

***

## Appendix A: task notes, phases 0–7

These tasks ran on ruby from a copy of this directory (`cd ~/wg`), and on jennie from `~/wg-jennie`, unless marked *on home*. They moved here from README.md and are kept as the record of how it was done; the phases above cite them as "Task N". Since then ruby and jennie each have a clone of the repo at `~/homelab`: new work runs from `~/homelab/wireguard`, and secrets are filled into the installed copy under `/etc`, never into the clone.

Order:

1. Fill in ruby's secrets.
2. Update ruby's firewall, and open ports on jennie.
3. ruby ↔ jennie (wg2).
4. jennie ↔ home (wg3).
5. Move ruby's wg0 to netplan and home to wg1.
6. Update clients.
7. Test everything.

Clients on jennie are independent of this order and have no section here: the steps are phase 8, and the design is README [Clients on jennie](README.md#clients-on-jennie).

Step 2 changes nothing for traffic that works today; the new rules only match interfaces and ports that aren't in use yet. Steps 3 and 4 add new tunnels and don't touch anything running. Step 5 is the only one with downtime.

### Task 1: Fill in secrets

**1a. ruby's existing wg0 key and PSKs, from the backup of the live config.**

```bash
sudo cat /etc/wireguard.bak-2026-10-08/wg0.conf | ./fill-secrets.py
```

This fills ruby's wg0 private key, the PSKs for mba, iphone-peet and mbp, and home's PSK (in `ruby/81-wireguard-wg1.yaml` and `home/wg1.conf`). It never prints secrets.

If it prints `live hook: …` lines, the old wg0 has `PostUp`/`PostDown` commands that stop running once wg-quick is retired. Client NAT and the forward rules are already in `/etc/nftables.conf`, so there probably aren't any. If there are, check whether `nftables.conf` or `wg-docker-user.service` already covers them before carrying anything over.

**1b. Check what's left.** Run `./fill-secrets.py </dev/null` at any time. After 1a, the only placeholders left should be:

- `jennie/*`: jennie's private keys and home's wg3 public key (filled on jennie in Tasks 3 and 4)
- `home/*`: router-side values (the router's own keys, and jennie's wg3 public key from Task 4)

### Task 2: Firewalls and forwarding

**2a. ruby: forwarding.** It's on in both families today, but not pinned down:

- **IPv4** is set by `/etc/systemd/network/10-netplan-ens3.network.d/networkd-ipforward.conf`.
- **IPv6** is only on because dockerd enables it.

On a networkd host, forwarding belongs in networkd itself (systemd 257 here), so make it global and explicit:

```bash
sudo install -D -m 644 ruby/networkd-forwarding.conf /etc/systemd/networkd.conf.d/forwarding.conf
sudo systemctl restart systemd-networkd    # re-reads networkd.conf; keeps existing addresses and tunnels
cat /proc/sys/net/ipv4/conf/all/forwarding /proc/sys/net/ipv6/conf/all/forwarding   # 1 and 1
```

**2b. ruby: nftables.** Review `ruby/nftables.conf.diff` (summarised in [Firewall on ruby](README.md#firewall-on-ruby)), then install it:

```bash
sudo cp -a /etc/nftables.conf /etc/nftables.conf.bak-$(date +%F)
cmp /etc/nftables.conf ruby/nftables.conf.orig \
  && echo "live file unchanged since the draft" || echo "LIVE FILE CHANGED: redo the edits"
sudo install -m 755 -o root -g root ruby/nftables.conf /etc/nftables.conf
sudo nft -c -f /etc/nftables.conf && sudo systemctl reload nftables     # reload, NOT restart
sudo nft list table inet filter | grep -E 'WGIFS|wg[0-2]|51821|51822'
sudo iptables -S | grep -c DOCKER                                       # Docker's rules still there
```

Use `reload`, not `restart`; see [Applying firewall changes](README.md#applying-firewall-changes). The `cmp` check guards against the live file having been edited since this draft was made. If it says the live file changed, redo the edits on the new version instead of overwriting it.

**2c. ruby: Docker's DOCKER-USER exceptions.** These are needed for any IPv6 forwarding (see [Docker's IPv6 forward policy is DROP](README.md#dockers-ipv6-forward-policy-is-drop)):

```bash
sudo install -m 644 -o root -g root ruby/wg-docker-user.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wg-docker-user.service
sudo ip6tables -S DOCKER-USER; sudo iptables -S DOCKER-USER             # three wg+ rules each
```

**2d. jennie: firewall and forwarding.** *On jennie.* jennie has no firewall yet, so `jennie/nftables.conf` becomes its whole firewall. The input policy is drop, so first check what jennie serves publicly:

```bash
sudo ss -tulpn | grep -vE '127\.0\.0\.|\[::1\]'   # anything listening beyond localhost
systemctl is-active docker                          # expected: inactive (see below if not)
```

- SSH (22) and WireGuard (51822 from ruby, 51823 from anywhere) are already allowed, over IPv6.
- Add a rule under "Public services" in `nftables.conf` for anything else that must stay reachable from the internet.
- Everything arriving over wg2/wg3 is accepted.
- If Docker turns out to be installed, stop and adapt first: its IPv6 FORWARD policy is drop (as on ruby), and jennie would need a copy of `ruby/wg-docker-user.service`, also allowing IPv6 `wg+ → ens3`.

Copy the files over (*run on ruby*):

```bash
scp ~/wg/jennie/networkd-forwarding.conf ~/wg/jennie/nftables.conf jennie:wg-jennie/
```

Enable forwarding (*on jennie*):

```bash
systemctl --version | head -1              # needs systemd >= 256 for IPv4Forwarding=/IPv6Forwarding=
sudo install -D -m 644 ~/wg-jennie/networkd-forwarding.conf /etc/systemd/networkd.conf.d/forwarding.conf
sudo systemctl restart systemd-networkd
cat /proc/sys/net/ipv4/conf/all/forwarding /proc/sys/net/ipv6/conf/all/forwarding   # 1 and 1
ip -6 route show default                   # still there (networkd handles RAs itself)
```

Apply the firewall with a **dead-man switch**: a timer that removes it again after 3 minutes, unless you cancel the timer from a *new* SSH session that proves you're not locked out.

```bash
sudo cp -a /etc/nftables.conf /etc/nftables.conf.bak-$(date +%F) 2>/dev/null   # Debian ships a stub
sudo install -m 755 -o root -g root ~/wg-jennie/nftables.conf /etc/nftables.conf
sudo nft -c -f /etc/nftables.conf && echo "syntax OK"
sudo systemd-run --on-active=180 --unit=nft-deadman /usr/sbin/nft delete table inet filter
sudo nft -f /etc/nftables.conf
# now open a NEW ssh session to jennie; if it works:
sudo systemctl stop nft-deadman.timer
sudo systemctl enable --now nftables       # load it at boot
sudo nft list ruleset | head -40
```

If the new session doesn't connect, wait 3 minutes: the timer deletes `inet filter` (input drop policy and forward rules) and access returns. The NAT table stays but does nothing harmful on its own.

Later changes: `sudo nft -c -f /etc/nftables.conf && sudo systemctl reload nftables`. Never `restart`, as on ruby.

**2e. ruby: renumber the dummy interfaces' IPv6.** `fd00::1` → `fd33:5692:1834:254::254` (dummy0) and `fd00::2` → `fd33:5692:1834:254::253` (dummy1). Nothing listens on the old addresses (checked with `ss`), and rspamd's `local_addrs` (`fd00::/8`) already covers the new ones. Do this before clients get IPv6 addresses (Task 6), so nothing ever uses the old addresses.

`ruby/70-dummy-interfaces.yaml` was written from the live addresses, because the live file isn't readable without root. Compare first; only the two IPv6 lines (and comments) should differ:

```bash
sudo diff /etc/netplan/70-dummy-interfaces.yaml ruby/70-dummy-interfaces.yaml
sudo cp -a /etc/netplan/70-dummy-interfaces.yaml /etc/netplan/70-dummy-interfaces.yaml.bak-$(date +%F)   # netplan only reads *.yaml
sudo install -m 600 -o root -g root ruby/70-dummy-interfaces.yaml /etc/netplan/
sudo netplan generate
sudo networkctl reload && sudo networkctl reconfigure dummy0 dummy1
ip -br addr show dummy0; ip -br addr show dummy1                          # new IPv6 only, no fd00::
```

If an old `fd00::` address lingers, remove it with `sudo ip -6 addr del fd00::1/128 dev dummy0` (and `fd00::2/128` on dummy1).

jennie's `82-wireguard-wg2.yaml` has the new addresses in its allowed IPs and routes. If you already installed an earlier copy on jennie, reinstall it there and recreate wg2: `sudo netplan generate && sudo ip link del wg2 && sudo networkctl reload`.

**2f. Provider firewalls.** Neither server has one (no OVH network firewall or security groups), so jennie's and ruby's nftables are the only filtering.

### Task 3: ruby ↔ jennie (wg2)

*On jennie.* Copy the files over and fill in jennie's wg2 key:

```bash
scp -r ~/wg/jennie jennie:wg-jennie        # run on ruby
```

```bash
# on jennie
cd ~/wg-jennie
sudo apt install wireguard-tools           # for the wg command; networkd does the tunnel itself
sed -i "s|<jennie wg2 private key>|$(sudo cat /etc/wireguard/jennie.key)|" 82-wireguard-wg2.yaml
#      ^ wherever jennie's wg2 private key was saved earlier
grep -n '<' 70-dummy0.yaml 82-wireguard-wg2.yaml || echo "wg2 files filled"
```

Check whether jennie already has a `dummy0`, and see what netplan files exist:

```bash
ip -br link show type dummy; ls -l /etc/netplan/
```

If `dummy0` is taken, rename it in `70-dummy0.yaml` (e.g. `dummy1`).

Install and bring up dummy0 and wg2:

```bash
# on jennie
sudo install -m 600 -o root -g root 70-dummy0.yaml 82-wireguard-wg2.yaml /etc/netplan/
sudo netplan generate
sudo networkctl reload
ip -br addr show dummy0; ip -br addr show wg2
```

*On ruby:*

```bash
sudo install -m 600 -o root -g root ruby/82-wireguard-wg2.yaml /etc/netplan/
sudo netplan generate
sudo networkctl reload
sudo wg show wg2      # recent handshake; endpoint [2001:41d0:801:2000::180f]:51822
```

`networkctl reload` creates the new interfaces without touching existing ones. `sudo netplan apply` also works, but it reconfigures every netplan-managed interface (including ens3).

Test from ruby:

```bash
ping -c3 172.31.1.6
ping -c3 fd33:5692:1834:ff02::2
ping -c3 192.168.254.2
ping -c3 fd33:5692:1834:254::2
ping -M do -c3 -s 1392 172.31.1.6               # MTU: 1420 - 28
ping -M do -c3 -s 1372 fd33:5692:1834:ff02::2   # MTU: 1420 - 48
```

### Task 4: jennie ↔ home (wg3)

This links the home LANs directly to jennie and doesn't affect anything else.

**4a. Keys.** On jennie, generate jennie's wg3 key:

```bash
# on jennie
(umask 077; wg genkey | sudo tee /etc/wireguard/wg3.key | wg pubkey)
cd ~/wg-jennie
sed -i "s|<jennie wg3 private key>|$(sudo cat /etc/wireguard/wg3.key)|" 83-wireguard-wg3.yaml
```

On home, create a **new WireGuard interface** for wg3 with its own key; most routers generate one when you create the interface. Then swap public keys:

```bash
# on jennie: home's wg3 public key
sed -i "s|<home wg3 public key>|PASTE_HOME_INET_WG3_PUBKEY|" 83-wireguard-wg3.yaml

# on ruby: jennie's wg3 public key, into the router reference
sed -i "s|<jennie wg3 public key>|PASTE_JENNIE_WG3_PUBKEY|" home/wg3.conf
```

**4b. jennie.**

```bash
# on jennie
grep -n '<' 83-wireguard-wg3.yaml || echo "wg3 file filled"
sudo install -m 600 -o root -g root 83-wireguard-wg3.yaml /etc/netplan/
sudo netplan generate
sudo networkctl reload
```

wg3 also gives jennie the lab's internal names. Its `nameservers` block sends `home.` and `8.168.192.in-addr.arpa` to Pythia (`192.168.8.52`) as routing-only domains, so systemd-resolved queries Pythia over wg3 for those names and nothing else. This goes direct, like all of jennie's traffic to home, rather than via ruby's stub zones. Themis and Delphi would refuse jennie's queries. If wg3 is down, `.home` stops resolving, but the lab is unreachable then anyway. Check with `resolvectl query pythia.home`.

**4c. home router.** Configure the new interface from `home/wg3.conf`:

| Setting              | Value |
|----------------------|-------|
| Interface            | new, e.g. `wg3` |
| Private key          | new, generated on the router (4a) |
| Tunnel address       | `172.31.1.10/30`, `fd33:5692:1834:ff03::2/64` |
| MTU                  | `1388` |
| Peer public key      | jennie's wg3 public key (4a) |
| Preshared key        | contents of `home-jennie.psk` (already in `home/wg3.conf`) |
| Endpoint             | `[2001:41d0:801:2000::180f]:51823` |
| Persistent keepalive | `25` |
| Peer allowed IPs     | `0.0.0.0/0, ::/0` (jennie is an internet exit) |
| Automatic routes     | **off** (wg-quick: `Table = off`). The router's GL client installs its default only in table 1002, so main-table traffic is unaffected |
| Routes via wg3       | `172.31.1.9/32`, `192.168.254.2/32`, `fd33:5692:1834:ff03::1/128`, `fd33:5692:1834:254::2/128`, as persistent `route`/`route6` entries on `wgclient2` |
| Internet via jennie  | GL route policy `UK` (tunnel 6611, mark `0x2000`), with targets in `/etc/domain_mac_list/dst_net6611_manual`. Table 1002 holds the default route via wg3 (IPv4 and IPv6). Other clients or destinations can be added as further policy rules |
| IPv6 NAT             | `ip6tables -t nat` MASQUERADE on `wgclient2`, in `/etc/firewall.user` (no IPv4 NAT). **Recommended:** limit it to non-VPN sources, so only ISP-sourced traffic is translated: `ip6tables -t nat -A POSTROUTING -o wgclient2 ! -s fd33:5692:1834::/48 -j MASQUERADE` |

**4d. Test.**

```bash
# on jennie
sudo wg show wg3                           # handshake from the router's IPv6 address
ping -c3 172.31.1.10
ping -c3 fd33:5692:1834:ff03::2
ping -c3 192.168.8.1                       # or any home LAN host
traceroute -n 192.168.8.1                  # first hop 172.31.1.10, not via ruby
ping -M do -c3 -s 1360 172.31.1.10         # MTU: 1388 - 28
```

If the MTU ping fails but smaller sizes work, the home link has a lower MTU. Lower it on both ends of wg3 (and wg1).

### Task 5: Move wg0 to netplan, move home to wg1

This is the only step with downtime:

- **Clients** drop for a few seconds while wg0 is recreated.
- **home ↔ ruby** is down from the moment wg0 stops until the router's wg1 is configured. home ↔ jennie keeps working over wg3.

Have the router settings from 5a ready before starting.

**5a. Prepare these settings on the home router.** Convert its existing tunnel to ruby into wg1, using `home/wg1.conf`:

| Setting              | Value |
|----------------------|-------|
| Interface            | the existing tunnel to ruby (rename to `wg1` if the router allows) |
| Private key          | **unchanged** (ruby's wg1 expects the router's existing public key, `vQww1GLu…`) |
| Tunnel address       | `172.31.1.2/30`, `fd33:5692:1834:ff01::2/64` (remove the old `192.168.204.5`) |
| MTU                  | `1388` |
| Peer public key      | ruby's wg1 key: `UFJld/qzjF6JzLwIVxayR48jfkZgTmTXhyPlK6txDCc=` |
| Preshared key        | **unchanged** (already in `home/wg1.conf` after Task 1a) |
| Endpoint             | `[2001:41d0:305:2100::1:3a0e]:51821` |
| Persistent keepalive | `25` |
| Peer allowed IPs     | `172.31.1.1/32, fd33:5692:1834:ff01::1/128, 192.168.204.0/24, fd33:5692:1834:204::/64, 192.168.254.253/32, 192.168.254.254/32, fd33:5692:1834:254::254/128, fd33:5692:1834:254::253/128` |
| Routes via wg1       | the same, minus the two transit addresses, if the router doesn't add routes from allowed IPs |
| LAN IPv6             | **Done** for lan (`fd33:5692:1834:1000::/64`) and iot (`…:1001::/64`), and guest (`…:1002::/64`, disabled). The ISP prefixes are kept (see [Home LANs and the ISP's IPv6](README.md#home-lans-and-the-isps-ipv6)) |

Remove any old routes on the router that pointed jennie's or ruby's networks at the old tunnel.

**5b. Install on ruby.** The files go in place first; nothing changes until wg-quick is stopped.

```bash
sudo install -m 600 -o root -g root ruby/80-wireguard-wg0.yaml ruby/81-wireguard-wg1.yaml /etc/netplan/
sudo netplan generate && echo "netplan OK"
```

**5c. Cut over.**

```bash
sudo systemctl disable --now wg-quick@wg0  # removes wg0 and its routes, runs its PostDown
sudo networkctl reload                     # networkd creates wg0 and wg1
```

Then apply the router settings from 5a.

**5d. Check from ruby.**

```bash
networkctl list                            # wg0, wg1, wg2: routable / configured
sudo wg show                               # wg0 clients reconnecting; wg1 handshake from an IPv6 address
ip route | grep -E 'wg[0-2]'
ip -6 route | grep -E 'wg[0-2]'
ping -c3 172.31.1.2
ping -c3 fd33:5692:1834:ff01::2
ping -c3 192.168.8.1                       # or any home LAN host
ping -c3 <a home host's ULA address>
ping -M do -c3 -s 1360 172.31.1.2          # MTU: 1388 - 28
```

**5e. IPv6 for BIND, Postfix and Dovecot.** Do this right after 5c. It needs wg0's IPv6 address (5c) and dummy0's renumbered address (Task 2e), and the Dovecot drop-in it replaces still refers to wg-quick. Review `ruby/services/services.diff` first.

Check the live files haven't changed since the copies were taken:

```bash
cd ~/wg/ruby/services
for f in $(cd orig && find etc -type f); do cmp -s "orig/$f" "/$f" && echo "unchanged: /$f" || echo "CHANGED:   /$f  (redo the edit on the new version)"; done
```

Start-order drop-ins. These change nothing until the next restart:

```bash
sudo install -m 644 etc/systemd/system/dovecot.service.d/dovecot-local-deps.conf /etc/systemd/system/dovecot.service.d/
sudo install -D -m 644 etc/systemd/system/postfix.service.d/local-deps.conf /etc/systemd/system/postfix.service.d/local-deps.conf
sudo systemctl daemon-reload
systemctl show -p After dovecot postfix | grep -o 'systemd-networkd-wait-online@[^ ]*'
```

BIND (picks up the new address without restarting):

```bash
sudo install -m 644 -o root -g bind etc/bind/named.conf.options etc/bind/named.conf.local /etc/bind/
sudo named-checkconf && sudo rndc reconfig
ss -ulnH 'sport = :53' | grep fd33          # [fd33:5692:1834:204::254]:53
```

Postfix:

```bash
sudo install -m 644 etc/postfix/master.cf /etc/postfix/master.cf
sudo postfix check && sudo systemctl restart postfix
ss -ltnH | grep -E ':(587|465)\b'           # 192.168.204.254 and [fd33:5692:1834:204::254], both ports
```

Dovecot:

```bash
sudo install -m 644 etc/dovecot/conf.d/20-managesieve.conf /etc/dovecot/conf.d/
sudo doveconf -n >/dev/null && sudo systemctl reload dovecot
ss -ltnH 'sport = :4190'                    # four addresses; if the IPv6 ones are missing: sudo systemctl restart dovecot
```

From a client with its IPv6 address (Task 6):

```bash
dig @fd33:5692:1834:204::254 mail.peetvandesande.com +short                      # 192.168.204.254
openssl s_client -connect '[fd33:5692:1834:204::254]:465' -brief </dev/null       # TLS handshake OK
nc -zv fd33:5692:1834:204::254 587 && nc -zv fd33:5692:1834:204::254 4190
```

From jennie and from a home LAN host (once wg1 and wg2/wg3 are up):

```bash
dig @192.168.204.254 mail.peetvandesande.com +short                              # 192.168.204.254 (split horizon)
dig @fd33:5692:1834:204::254 mail.peetvandesande.com +short                      # same, over IPv6
nc -zv 192.168.204.254 587 && nc -zv 192.168.204.254 4190
```

### Task 6: Update the clients

Each client keeps its keys, PSK and endpoint. Only `Address` and `AllowedIPs` change:

```ini
[Interface]
Address = 192.168.204.1/32, fd33:5692:1834:204::1/128     # mba; iphone-peet .2 / ::2, mbp .4 / ::4
```

Pick one `AllowedIPs` line:

```ini
# Full tunnel: IPv4 internet via ruby (or jennie, if opted in on ruby), IPv6 internet via jennie
AllowedIPs = 0.0.0.0/0, ::/0

# VPN networks only
AllowedIPs = 192.168.204.0/24, 192.168.8.0/21, 192.168.254.2/32, 192.168.254.253/32, 192.168.254.254/32, fd33:5692:1834:204::/64, fd33:5692:1834:1000::/56, fd33:5692:1834:254::2/128, fd33:5692:1834:254::254/128, fd33:5692:1834:254::253/128
```

The split-tunnel list only contains networks ruby actually routes. Clients don't need the `172.31.1.0/24` transit addresses.

Which exit a client uses isn't set on the client: it's decided by ruby's routing-policy rules (see [Internet exits](README.md#internet-exits)).

Test from a client:

```bash
ping 192.168.204.254 && ping6 fd33:5692:1834:204::254   # ruby
ping 192.168.254.2   && ping6 fd33:5692:1834:254::2     # jennie, via ruby
ping 192.168.8.1                                         # home, via ruby
curl -4 https://ifconfig.co                              # full tunnel: 46.105.253.72 (ruby), or 57.129.180.73 if opted in to jennie
curl -6 https://ifconfig.co                              # full tunnel: 2001:41d0:801:2000::180f (jennie)
```

### Task 7: Test end to end and reboot

```bash
# on jennie
ping -c3 192.168.204.1                     # a client, via ruby (wg2)
ping -c3 fd33:5692:1834:204::1
ping -c3 192.168.254.254                   # ruby's dummy0
traceroute -n 192.168.8.1                  # direct over wg3 (first hop 172.31.1.10)

# from a home LAN host
traceroute -n 192.168.204.1                # via ruby (172.31.1.1)
traceroute -n 192.168.254.2                # via jennie (172.31.1.9)

# from a home host the router sends via jennie (e.g. the laptop)
curl -4 https://ifconfig.co                # 57.129.180.73
curl -6 https://ifconfig.co                # 2001:41d0:801:2000::180f

# on ruby: the exit policy
ip rule; ip -6 rule                        # priorities 900 (main) and 1000 (table 200)
ip route show table 200; ip -6 route show table 200

# on jennie: NAT counters go up as exit traffic flows
sudo nft list table inet wgnat
```

Reboot ruby and jennie (one at a time) to confirm everything comes back on its own (netplan, nftables, `wg-docker-user.service`):

```bash
networkctl list; sudo wg show; sudo ip6tables -S DOCKER-USER; sudo iptables -S DOCKER-USER   # ruby
networkctl list; sudo wg show; sudo nft list tables; cat /proc/sys/net/ipv4/conf/all/forwarding /proc/sys/net/ipv6/conf/all/forwarding   # jennie
```

### Task 8: Clean up

```bash
# on ruby, once everything has run fine for a while
shred -u ~/wg/wg1.key ~/wg/wg2.key ~/wg/jennie.psk ~/wg/home-jennie.psk
# the filled YAML/conf files in ~/wg also contain secrets: shred them, or keep ~/wg as a 700 directory

# on jennie
shred -u ~/wg-jennie/*.yaml
```

The old `/etc/wireguard/wg0.conf` on ruby is no longer used. Keep it until you're confident you won't roll back, then remove it along with `/etc/wireguard.bak-2026-10-08`.

Remove sylvie from any other place it's referenced (DNS, monitoring).

***

## Appendix B: rollback

**ruby: back to wg-quick wg0.** No longer possible as written: Task 8 removed `/etc/wireguard/wg0.conf` and its backup. Kept for reference; restore the config from `~/projects/homelab-private/wireguard/superseded/` first if it's ever needed:

```bash
sudo rm /etc/netplan/80-wireguard-wg0.yaml /etc/netplan/81-wireguard-wg1.yaml
sudo netplan generate
sudo ip link del wg1
sudo ip link del wg0                       # networkd doesn't remove links it no longer manages
sudo systemctl enable --now wg-quick@wg0
```

Then put the router's tunnel back to its old settings: address `192.168.204.5`, endpoint port 51820, ruby's wg0 public key.

To remove wg2 or wg3, delete that YAML file on both ends, then run `netplan generate` and `ip link del wgN`.

**jennie: clients (phase 8).** Nothing else depends on it, so it comes out on its own:

```bash
# on jennie
sudo rm /etc/netplan/80-wireguard-wg0.yaml && sudo netplan generate && sudo ip link del wg0
sudo systemctl disable --now named         # or apt purge bind9
sudo cp -a /etc/nftables.conf.bak-YYYY-MM-DD /etc/nftables.conf && sudo systemctl reload nftables

# on ruby: remove the two 205 routes from /etc/netplan/82-wireguard-wg2.yaml, then
sudo netplan generate
sudo ip route del 192.168.205.0/24 dev wg2; sudo ip -6 route del fd33:5692:1834:205::/64 dev wg2

# on home
uci delete network.s2s_wgclient2_205; uci delete network.s2s_wgclient2_205_6
uci commit network && /etc/init.d/network reload
```

**ruby: services (Task 5e).** Put the originals back, *before* rolling wg0 back to wg-quick. Otherwise Postfix and Dovecot try to bind IPv6 addresses that no longer exist:

```bash
cd ~/wg/ruby/services
for f in $(cd orig && find etc -type f); do sudo cp "orig/$f" "/$f"; done
sudo rm /etc/systemd/system/postfix.service.d/local-deps.conf
sudo systemctl daemon-reload
sudo named-checkconf && sudo rndc reconfig
sudo postfix check && sudo systemctl restart postfix
sudo systemctl restart dovecot
```

**ruby: firewall.** The new rules are harmless with the old setup, so this is only needed if the firewall change itself causes trouble:

```bash
sudo cp -a /etc/nftables.conf.bak-YYYY-MM-DD /etc/nftables.conf
sudo systemctl reload nftables             # reload, NOT restart
sudo systemctl disable --now wg-docker-user.service
```
