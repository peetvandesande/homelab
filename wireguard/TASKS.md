# WireGuard rollout: task list

Every remaining step, in order, from where things stand on 2026-10-09. Explanations, full test output and rollback are in [README.md](README.md); each task names its README section.

Unless a task says otherwise, run commands **on ruby** from `~/wg`. *On jennie* means in `~/wg-jennie` on jennie. *On home* means the home router's own UI or CLI.

`[x]` = done (verified on ruby 2026-10-09), `[ ]` = to do. Phases 1–3 don't disturb anything running; phase 4 is the only one with downtime.

***

## Phase 0: Done

- [x] Back up `/etc/wireguard` → `/etc/wireguard.bak-2026-10-08`
- [x] Generate ruby's wg1/wg2 keys, the ruby–jennie PSK (`jennie.psk`) and the home–jennie PSK (`home-jennie.psk`)
- [x] Generate jennie's wg2 key on jennie (public key `+0MxQ46p…`)
- [x] Fill ruby's wg0 key and the client/home PSKs (`fill-secrets.py`, README Task 1a)
- [x] Install ruby's new `/etc/nftables.conf` (README Task 2b)
- [x] Install and enable `wg-docker-user.service` (README Task 2c)
- [x] Install ruby's `82-wireguard-wg2.yaml`; wg2 is up with the via-jennie table 200 and its rules
- [x] Publish the WordPress container on loopback only (`/opt/wordpress-sogode/docker-compose.yml`)
- [x] jennie: dummy0 and wg2 up. ruby reaches `172.31.1.6`, `fd33:5692:1834:ff02::2`, `192.168.254.2` and `fd33:5692:1834:254::2` (checked 2026-10-09).
- [x] jennie: wg3 up (reported from home)
- [x] home: wg3 (`wgclient2`) configured and up, with main-table routes to jennie, table 1002 with GL route policy `UK` (BBC domains and jennie's dummy), and IPv6 masquerade in `/etc/firewall.user`
- [x] home: global ULA `fd33:5692:1834::/48`; LAN `/64`s lan `1000::`, iot `1001::`, guest `1002::` (disabled); iot's stray `/60` fixed

***

## Phase 1: ruby preparation (no impact)

- [ ] **1.1 Forwarding owned by networkd** (README Task 2a). IPv6 forwarding currently depends on Docker.
  ```bash
  sudo install -D -m 644 ruby/networkd-forwarding.conf /etc/systemd/networkd.conf.d/forwarding.conf
  sudo systemctl restart systemd-networkd
  cat /proc/sys/net/ipv{4,6}/conf/all/forwarding          # 1, 1
  ```
- [ ] **1.2 Renumber ruby's dummy IPv6** `fd00::1/2` → `fd33:5692:1834:254::254/253` (README Task 2e)
  ```bash
  sudo diff /etc/netplan/70-dummy-interfaces.yaml ruby/70-dummy-interfaces.yaml   # only the IPv6 lines differ
  sudo cp -a /etc/netplan/70-dummy-interfaces.yaml /etc/netplan/70-dummy-interfaces.yaml.bak-$(date +%F)
  sudo install -m 600 ruby/70-dummy-interfaces.yaml /etc/netplan/
  sudo netplan generate && sudo networkctl reload && sudo networkctl reconfigure dummy0 dummy1
  ip -br addr show dummy0; ip -br addr show dummy1      # fd33:…:254::254 / ::253, no fd00::
  ```
- [ ] **1.3 (cosmetic) Refresh the firewall comments** renamed from home-inet to home
  ```bash
  sudo install -m 755 ruby/nftables.conf /etc/nftables.conf
  sudo nft -c -f /etc/nftables.conf && sudo systemctl reload nftables   # reload, NOT restart
  ```
- [ ] **1.4 Provider firewall** (README Task 2f). If OVH's network firewall or security groups are in use: ruby UDP 51821–51822 over IPv6; jennie UDP 51822–51823 over IPv6.

***

## Phase 2: jennie, firewall and forwarding

wg2, wg3 and dummy0 are already up on jennie. What's left is forwarding and the firewall, and **the internet exit depends on them**: until 2.3 and 2.4 are done, traffic the home router sends to jennie for BBC (and client IPv6 sent via ruby's table 200) has no NAT on jennie and goes nowhere.

- [ ] **2.1 Checks** (*on jennie*, README Task 2d)
  ```bash
  systemctl --version | head -1                  # >= 256
  sudo ss -tulpn | grep -vE '127\.0\.0\.|\[::1\]'  # public services to add under "Public services" in nftables.conf
  systemctl is-active docker                     # expected inactive; if active, see README Task 2d first
  ip -br link show type dummy                    # dummy0 free? otherwise rename it in 70-dummy0.yaml
  ```
- [ ] **2.2 Copy jennie's files** (*on ruby*). If jennie's wg2/wg3 were set up some other way, compare them with `jennie/*.yaml`, especially wg2's allowed IPs and routes for ruby's renumbered dummies.
  ```bash
  scp -r ~/wg/jennie jennie:wg-jennie
  ```
- [x] **2.3 Forwarding** (*on jennie*)
  ```bash
  sudo install -D -m 644 networkd-forwarding.conf /etc/systemd/networkd.conf.d/forwarding.conf
  sudo systemctl restart systemd-networkd
  cat /proc/sys/net/ipv{4,6}/conf/all/forwarding; ip -6 route show default
  ```
- [x] **2.4 Firewall with a dead-man switch** (*on jennie*, README Task 2d)
  ```bash
  sudo cp -a /etc/nftables.conf /etc/nftables.conf.bak-$(date +%F) 2>/dev/null
  sudo install -m 755 nftables.conf /etc/nftables.conf && sudo nft -c -f /etc/nftables.conf
  sudo systemd-run --on-active=180 --unit=nft-deadman /usr/sbin/nft delete table inet filter
  sudo nft -f /etc/nftables.conf
  # NEW ssh session to jennie works? then:
  sudo systemctl stop nft-deadman.timer && sudo systemctl enable --now nftables
  ```
- [x] **2.5 dummy0 and wg2** (*on jennie*, README Task 3)
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

- [x] **3.1 Keys** (README Task 4a)
  - *On jennie:* `(umask 077; wg genkey | sudo tee /etc/wireguard/wg3.key | wg pubkey)` → give the public key to home
  - *On home:* create a new WireGuard interface `wg3` with its own key → give its public key to jennie
  - *On jennie:* fill `83-wireguard-wg3.yaml` with jennie's wg3 private key and home's wg3 public key
  - *On ruby:* `sed -i "s|<jennie wg3 public key>|PUBKEY|" home/wg3.conf` (reference copy)
- [x] **3.2 Install wg3** (*on jennie*)
  ```bash
  grep -n '<' 83-wireguard-wg3.yaml || echo filled
  sudo install -m 600 83-wireguard-wg3.yaml /etc/netplan/ && sudo netplan generate && sudo networkctl reload
  ```
- [x] **3.3 Configure home's wg3** (*on home*, README Task 4c, `home/wg3.conf`): done as `wgclient2`, with GL route policy `UK`
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

***

## Phase 4: cutover, ruby wg0/wg1 and services (downtime)

Clients drop for a few seconds; home ↔ ruby is down until 4.5. Have 4.1 ready first, and do 4.3–4.4 in one go: Dovecot's current drop-in still refers to wg-quick.

- [ ] **4.1 Prepare home's wg1 settings** (*on home*, README Task 5a, `home/wg1.conf`)
  - keep the router's key and PSK; peer key → ruby's wg1 `UFJld/qz…` (`wg1.pub`)
  - address `172.31.1.2/30`, `fd33:5692:1834:ff01::2/64` (remove `192.168.204.5`), MTU 1388
  - endpoint `[2001:41d0:305:2100::1:3a0e]:51821`, keepalive 25
  - allowed IPs/routes: `172.31.1.1/32, fd33:5692:1834:ff01::1/128, 192.168.204.0/24, fd33:5692:1834:204::/64, 192.168.254.253/32, 192.168.254.254/32, fd33:5692:1834:254::254/128, fd33:5692:1834:254::253/128`
  - ~~LANs: ULA `/64` per LAN~~ done (Phase 0)
- [ ] **4.2 Stage the netplan files** (README Task 5b)
  ```bash
  sudo install -m 600 ruby/80-wireguard-wg0.yaml ruby/81-wireguard-wg1.yaml /etc/netplan/
  sudo netplan generate && echo OK
  cd ruby/services && for f in $(cd orig && find etc -type f); do cmp -s "orig/$f" "/$f" && echo "unchanged /$f" || echo "CHANGED /$f"; done; cd ~/wg
  ```
- [ ] **4.3 Cut over** (README Task 5c)
  ```bash
  sudo systemctl disable --now wg-quick@wg0
  sudo networkctl reload
  networkctl list | grep -E 'wg[0-2]'                  # configured
  ```
- [ ] **4.4 Services: IPv6 and VPN-wide DNS, start order** (README Task 5e, review `ruby/services/services.diff`)
  ```bash
  cd ~/wg/ruby/services
  sudo install -m 644 etc/systemd/system/dovecot.service.d/dovecot-local-deps.conf /etc/systemd/system/dovecot.service.d/
  sudo install -D -m 644 etc/systemd/system/postfix@-.service.d/local-deps.conf /etc/systemd/system/postfix@-.service.d/local-deps.conf
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
- [ ] **4.5 Apply home's wg1 settings** from 4.1 (*on home*)
- [ ] **4.6 Check** (README Task 5d)
  ```bash
  sudo wg show                                          # wg0 clients back; wg1 handshake from an IPv6 address
  ip route | grep -E 'wg[0-2]'; ip -6 route | grep -E 'wg[0-2]'
  ping -c3 172.31.1.2; ping -c3 192.168.8.1; ping -M do -c3 -s 1360 172.31.1.2
  ```

***

## Phase 5: clients

- [ ] **5.1 Update each client** (mba, iphone-peet, mbp; README Task 6). Keep keys, PSK and endpoint.
  - `Address = 192.168.204.N/32, fd33:5692:1834:204::N/128`
  - full tunnel: `AllowedIPs = 0.0.0.0/0, ::/0`, or the split-tunnel list from README Task 6
  - DNS: `192.168.204.254` (optionally also `fd33:5692:1834:204::254`)
- [ ] **5.2 Choose IPv4 exits.** All clients use ruby by default; to send one via jennie, add `- { from: "192.168.204.N/32", table: 200, priority: 1000 }` to `ruby/82-wireguard-wg2.yaml` (README Day-to-day)
- [ ] **5.3 Test from a client**
  ```bash
  ping 192.168.204.254; ping6 fd33:5692:1834:204::254; ping 192.168.254.2; ping 192.168.8.1
  dig @fd33:5692:1834:204::254 mail.peetvandesande.com +short       # 192.168.204.254
  curl -4 https://ifconfig.co      # 46.105.253.72 (or 57.129.180.73 if opted in)
  curl -6 https://ifconfig.co      # 2001:41d0:801:2000::180f (jennie)
  ```

***

## Phase 6: end to end and reboots

- [ ] **6.1 Service access from every site** (README Task 5e). *On jennie* and *from a home host*: `dig @192.168.204.254 mail.peetvandesande.com +short`, `dig @192.168.204.254 pythia.home +short` (192.168.8.52), `dig @192.168.204.254 -x 192.168.8.52 +short`, `nc -zv 192.168.204.254 587`, `nc -zv 192.168.204.254 4190`, and the same over `fd33:5692:1834:204::254`
- [ ] **6.2 Paths** (README Task 7). *On jennie:* `traceroute -n 192.168.8.1` goes direct over wg3. *From home:* `traceroute -n 192.168.204.1` goes via ruby, and `traceroute -n 192.168.254.2` via jennie.
- [ ] **6.3 Reboot ruby**, then check: `networkctl list`, `sudo wg show`, `ip rule`, `sudo ip6tables -S DOCKER-USER`, `systemctl is-active postfix dovecot named`, and `ss -lnt` for 587/465/4190 on both families
- [ ] **6.4 Reboot jennie**, then check: `networkctl list`, `sudo wg show`, `sudo nft list ruleset | head`, `cat /proc/sys/net/ipv{4,6}/conf/all/forwarding`

***

## Phase 7: cleanup

- [ ] **7.1 Secrets in `~/wg`:** `shred -u wg1.key wg2.key jennie.psk home-jennie.psk`; shred or lock down the filled YAML/conf files; *on jennie*, `shred -u ~/wg-jennie/*.yaml`
- [ ] **7.2** Delete `~/wg/superseded/`
- [ ] **7.3** Once rollback is no longer needed: remove `/etc/wireguard/wg0.conf` and `/etc/wireguard.bak-2026-10-08`, and the `.bak-*` files in `/etc/netplan` and `/etc/nftables.conf.bak-*`

***

## Follow-ups (optional, outside the rollout)

- [ ] **BIND reverse zone `204.168.192.in-addr.arpa`:** remove the stale PTRs `3 sylvie` and `5 home-inet`, and bump the serial
- [ ] **BIND, optional:** reverse zones for `172.31.1.0/24` and `fd33:5692:1834::/48` (`4.3.8.1.2.9.6.5.3.3.d.f.ip6.arpa`), so reverse lookups of tunnel and ULA addresses don't time out; an `AAAA fd33:5692:1834:204::254` for the split-horizon `mail.peetvandesande.com`
- [ ] **Postfix:** `wireguard_clients.cidr` isn't referenced. Either wire it into `mua_client_restrictions` (extended to the VPN ranges) or correct the `main.cf` comments that say it's in use. Update `main.cf`'s header, which still describes the VPN as `192.168.204.0/24 (wg0)`.
- [ ] **WordPress:** commit the `docker-compose.yml` loopback change in `/opt/wordpress-sogode` (that repo had other uncommitted edits)
- [ ] **nginx:** `/etc/nginx/sites-available/sogode.com.wordpress` (not enabled) proxies to the container's bridge address on 19080, which can't work; fix it or delete it
- [ ] **Failover:** with static routing, a wg3 outage cuts jennie off from home. BIRD or FRR (OSPF) over wg1/wg2/wg3 could reroute via ruby.
- [ ] **Remove sylvie** wherever else it's referenced (monitoring, password managers, …)
- [ ] **Home, BBC policy and DNS:** the `UK` rule is domain-based through dnsmasq. Devices using their own DNS (browser DoH, iCloud Private Relay) bypass it. Disable DoH on the devices that need BBC, or block it on the router.
- [ ] **Home, `home/wg3.conf`:** fill in `<jennie wg3 public key>` in the reference copy (`sed -i "s|<jennie wg3 public key>|PUBKEY|" home/wg3.conf`), so it matches the router
