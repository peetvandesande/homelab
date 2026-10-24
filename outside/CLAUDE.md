# outside

ruby and jennie seen from the internet. Each runs `prometheus-blackbox-exporter`
and probes the **other's** public side; home Prometheus scrapes each exporter
over that server's own tunnel, and the rules in
`grafana/.../alerting/outside.yaml` deliver through Home Assistant.

| Vantage | Probes | Scraped over |
|---|---|---|
| jennie | ruby: SMTP :25 with STARTTLS, HTTPS sogode.com, ruby.peetvandesande.com, peetvandesande.com (404) – each over IPv4 and IPv6 | wg3, `192.168.254.2:9115` |
| ruby | jennie: ping, IPv4 and IPv6 | wg1, `192.168.254.254:9115` |

The probe list is the `outside-*` jobs in `prometheus/.../prometheus.yml`; this
directory holds only what runs on the two servers.

```
etc/prometheus/blackbox.yml       the modules, identical on both
etc/default/...                   listen address (@@ADDR@@)
etc/systemd/system/...d/          wait for dummy0, CAP_NET_RAW
install.sh                        sudo ~/homelab/outside/install.sh
```

Grafana Cloud Synthetic Monitoring was tried first and dropped on 16 October
2026: the free stack is paused when nobody logs in, and a paused stack
evaluates no alerts.

## Invariants

1. **Probe public IP literals, never names.** Both servers' BIND answers
   `mail.`, `ruby.peetvandesande.com` and `sogode.com` with ruby's tunnel
   addresses (`wireguard/`, split-horizon), so a probe by name would test the
   tunnel. The modules carry the Host header and TLS server name instead, one
   module per site, and never follow redirects, which would resolve a name.
   If ruby's public addresses change, change the targets.

2. **Each server is scraped over its own tunnel, so either can report the
   other.** ruby down: jennie's probes of it fail, and ruby's exporter stops
   answering. Both alerts, and both say "ruby". Do not route one scrape through
   the other server.

3. **The exporters listen only on dummy0, and scrapes are plain HTTP.**
   dummy0 is reachable only through WireGuard: jennie's input chain admits the
   tunnels and drops the rest, and ruby's nftables admits `:9115` only from
   `192.168.8.53` (`wireguard/ruby/nftables.conf`). Neither server holds a lab
   certificate, so this is a listed exception to the lab's TLS rule
   (`prometheus/CLAUDE.md` invariant 5).

4. **`http_ca` is the only module that must stay plain HTTP.** It probes the
   lab CA's published files on ruby (`ca/ruby/`): `/g3/` reverse-proxied from
   pistis over wg1, `/g2/` static. Those URLs are frozen into certificates as
   `http://`
   and cannot be changed; a client needs the files *in order to* establish
   trust, so requiring TLS would be circular. The module asserts a bare 200
   with redirects unfollowed, which is what catches an http-to-https redirect
   being added on ruby. Unlike the other probes the `/g3/` targets depend on
   the home line and wg1 — ruby serves from its nginx cache while they are
   down, so a failure there means the outage has outlasted the cache, which is
   also when a real client starts failing. The `/g2/` target does not: it is a
   local file, so it failing is nginx or a missing install.

5. **A shared outage at OVH is reported, but less precisely.** Both servers
   are OVH. If both drop, both probers are unreachable as well, so the alerts
   are `outside-vantage-down` for each rather than per-service failures.

## Debugging a failing probe

Run it by hand on the vantage server, with the module and target from the
alert:

```sh
curl -s "http://192.168.254.2:9115/probe?module=smtp_mail&target=145.239.73.18:25&debug=true"
```

`debug=true` prints every step of the conversation, which is how you see which
`expect` did not match.
