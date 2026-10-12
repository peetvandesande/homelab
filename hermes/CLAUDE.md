# hermes

VM 109, **192.168.8.57**, `Infrastructure` pool. **mailcow** for the Proxmox
labs: the made-up customers in a lab get real mailboxes, and their mail is read
in SOGo at **`https://hermes.home/SOGo/`**. The admin UI is
`https://hermes.home/`.

It never talks to the internet as a mail server. Labs hand it mail; it keeps
mail for the domains it hosts and bounces the rest.

## Working on this

`root/` mirrors the VM filesystem and is the source of truth for what this repo
owns. mailcow itself is a git clone at `/opt/mailcow-dockerized`, managed by
mailcow's own `update.sh`, not by this repo.

```
scripts/create-vm.sh   on lenora: create VM 109 from the Debian 13 cloud image
scripts/bootstrap.sh   from the workstation: Docker, node-exporter, mailcow clone + config
scripts/deploy.sh      push root/, apply mailcow.conf overrides, certificate, compose up
scripts/verify.sh      TLS, relay policy, containers, scrape and logs
```

From scratch: router reservation for `BC:24:11:1B:5D:14` → `create-vm.sh` →
`bootstrap.sh` → `ca/scripts/enrol.sh 192.168.8.57 hermes` →
`node-exporter/scripts/deploy.sh 192.168.8.57` →
`alloy/scripts/deploy.sh 192.168.8.57` → `prometheus/scripts/deploy.sh` →
`deploy.sh` → `verify.sh`.

## Why a VM

mailcow does not support LXC, and it wants a whole Docker host of its own
(ports 25 and 443, its own networks, netfilter rules). moby is neither.
It runs on the Debian cloud image with cloud-init, so it boots with the key
already in place. `bootstrap.sh` moves that key from `debian` to root, and
root is the only login after that.

## As light as mailcow goes

`root/etc/homelab-mailcow/mailcow.conf.overrides` is applied key by key on
every deploy. It skips ClamAV, Olefy, full-text search and ACME. Rspamd cannot
be skipped. The skipped containers still start, idle, because that is how
mailcow does it. SOGo stays: it is the webmail, and the webmail is the reason
this VM exists. Everything else in `mailcow.conf`, including every password, is
generated on the VM and stays there.

## Invariants

1. **Nothing leaves by default.** `extra.cf` sets
   `default_transport = error:...`, so mail for a domain hermes does not host
   bounces back to the sender with a clear reason. It is never tried against
   the internet. A lab that sends to a domain nobody created gets a bounce. It
   does not get silence.

2. **Going out via ruby is a per-domain exception.** Add a mailcow transport
   map (Configuration → Routing → Transport maps): destination domain, next
   hop ruby's submission port on `192.168.254.254`, with credentials. Transport
   maps are consulted before `default_transport`, so that domain, and nothing
   else, goes out. `192.168.254.254` is reachable from the LAN through the
   Main VPN policy (`router/README.md`). Do not set a mailcow relayhost
   instead: that applies per *sender* domain, and a lab's whole domain would
   start leaving.

3. **mynetworks is the only authorisation the labs need, and it is narrow.**
   `192.168.32.0/21` plus `192.168.8.21/32`, because an SDN zone that SNATs
   shows up as lenora. The rest of the LAN must authenticate.
   `homelab-local-addrs.map` repeats the list for Rspamd, so mail from a lab
   is not greylisted. Without that, an app's first message gets a 451, and a
   lab app may never retry it. Keep the two lists in step.

4. **IPv6 must stay enabled in Docker, not just in mailcow.conf.** If Docker
   has no IPv6 on mailcow's network, a client arriving over v6 is proxied, and
   postfix sees it as the Docker gateway. The gateway is inside mynetworks, so
   any v6 client becomes an open relay. `daemon.json` carries `"ipv6": true`,
   and `verify.sh` attempts a relay from the workstation over both families
   and expects "Relay access denied" (454) each time.

5. **`extra.cf` starts with `myhostname = hermes.home`, on purpose.** mailcow's
   postfix entrypoint rewrites the file on every start so that line comes
   first. Matching that in the repo keeps the copy on the VM identical, so
   `deploy.sh`'s change detection does not restart postfix on every run.

6. **`override.d/options.inc` replaces mailcow's `local.d/options.inc`.** It
   repeats mailcow's settings and differs only in `local_addrs`. After a
   mailcow update, diff it against upstream's copy.

7. **The certificate is the host's own, copied in.** `30-mailcow` copies
   `/etc/homelab-tls/host.{crt,key}` into `data/assets/ssl/` and restarts
   postfix, dovecot and nginx, but only when they differ. `host.crt` is already
   leaf plus intermediate, which all three need.

## Adding a lab's customers

Per domain in the admin UI: Mail Setup → Domains → add `acme.test`, then the
mailboxes. A lab that wants to do this from its bootstrap can use the mailcow
API. Set `API_KEY` and `API_ALLOW_FROM=192.168.8.21` in `mailcow.conf`, the same
shape as Pythia's API for lab zones, so only lenora can call it. That is not
set up yet.

Lab hosts send to `192.168.8.57:25` as their smarthost and need no MX records.
An app that insists on MX lookup needs an MX in the lab's own `<lab>.home` zone,
pointing at `hermes.home`.

## Monitoring

node-exporter and Alloy like every host. mailcow has no Prometheus endpoint,
so `homelab-mailcow-textfile` publishes `mailcow_container_up{service=...}`
every minute through the textfile collector, and the `mailcow-container-down`
rule in `grafana/` watches it. The engine logs to journald, so every
container's output is in Loki under `{host="hermes"}` with a `container` label.

## Updating mailcow

```sh
ssh root@192.168.8.57 'cd /opt/mailcow-dockerized && ./update.sh'
```

Then run `deploy.sh` again. `update.sh` can rewrite `mailcow.conf`, and the
deploy reapplies the overrides.
