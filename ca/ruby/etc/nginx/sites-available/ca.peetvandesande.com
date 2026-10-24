# ca.peetvandesande.com on ruby - the public face of the lab CA's published
# files. Managed in homelab/ca/ruby; installed by ca/scripts/install-ruby.sh.
#
# Publicly this name is a CNAME to vps-5ca50660.vps.ovh.net (145.239.73.18),
# which is this host. Inside the lab it is split-horizon on Pythia and answers
# pistis (192.168.8.55) directly - see homelab/dns/CLAUDE.md invariant 5. So
# the same URL is served two ways, and this vhost is the only one the internet
# can reach. Before it existed, every /g2/ and /g3/ URL frozen into a
# certificate returned 404 from outside the LAN.
#
# THE TWO GENERATIONS ARE SERVED DIFFERENTLY, ON PURPOSE:
#
#   /g3/  reverse-proxied to pistis, which is the live issuing CA. Its files
#         change whenever deploy.sh publishes, so a copy here would be a
#         second source of truth that silently goes stale.
#   /g2/  served statically from /var/www/ca.g2. The pre-G3 hierarchy is not
#         live: its one file is the root CRL, which only changes when something
#         is revoked off the root. pistis is a G3 host and holds no /g2/ at
#         all, so there is nothing there to proxy to.
#
# Both are plain HTTP, and NEITHER MAY REDIRECT TO HTTPS. The URLs inside the
# certificates are http:// and cannot be changed - frozen into G3 until 2036,
# and into three older certificates until 2026, 2029 and 2035. These are the
# files a client needs *in order to* establish trust, so requiring TLS to fetch
# them is circular; all of them are signed objects that verify on their own.
# Many CRL and AIA fetchers speak no TLS at all, and to those a 301 is
# indistinguishable from a failure.
#
# There is deliberately no listen 443 here. ruby holds no certificate for this
# name, nothing references https for it, and adding one would invite exactly
# the redirect the paragraph above forbids.

server {
    listen 80;
    listen [::]:80;
    server_name ca.peetvandesande.com;

    access_log /var/log/nginx/ca.access.log;
    error_log  /var/log/nginx/ca.error.log;

    # ------------------------------------------------------------------ /g3/
    # The path is G3's crlDistributionPoints and authorityInfoAccess, so it is
    # baked into every certificate issued under it and cannot be renamed.
    location /g3/ {
        # RESOLVED AT RUNTIME, NOT AT CONFIG LOAD. A literal name in
        # proxy_pass is resolved once, when nginx reads the config, and a
        # failure there is fatal: "host not found in upstream" and nginx does
        # not start - taking sogode.com and webmail with it, because they share
        # this nginx. wg1 or named being slow at boot is enough to trigger it.
        # Going through a variable forces per-request resolution instead, so a
        # DNS failure is a 502 on this location alone, which the cache below
        # then absorbs. It also means a changed address is picked up on TTL
        # expiry rather than needing a reload.
        #
        # 127.0.0.1 is this host's own named, which has a static-stub for
        # home. pointing at Pythia (wireguard/ruby/services/etc/bind/
        # named.conf.local).
        #
        # ipv6=off is about what is PUBLISHED, not what exists. Every lab host
        # has two IPv6 addresses: a ULA from fd33:5692:1834:1000::/64, which
        # IS in wg1's AllowedIPs and would be reachable from here, and a GUA
        # from the ISP's delegated prefix, which deliberately is not and which
        # renumbers with the lease (wireguard/README.md, "Home LANs and the
        # ISP's IPv6"). So a ULA AAAA would work - pistis's nginx already
        # listens on [::]:80. What is missing is the record: home. carries no
        # AAAA for any host, and step-ca binds 192.168.8.55:8443 alone, so
        # pistis is not dual-stack, only its nginx is. Turning this on means
        # adding the AAAA in dns/ first. Note it would change little
        # elsewhere: RFC 6724 ranks a ULA below IPv4, so ordinary clients keep
        # choosing IPv4 for a dual-answer name - nginx's resolver is the
        # exception that would not.
        resolver 127.0.0.1 valid=30s ipv4=on ipv6=off;
        resolver_timeout 3s;
        set $pistis pistis.home;
        proxy_pass http://$pistis$request_uri;

        # pistis's vhost lists ca.peetvandesande.com in its server_name, so
        # passing the original Host lands on the right server block there
        # rather than on its default.
        proxy_set_header Host              ca.peetvandesande.com;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        # Fail fast to the cache. A dead tunnel should cost a client three
        # seconds, not the default 60.
        proxy_connect_timeout 3s;
        proxy_send_timeout    5s;
        proxy_read_timeout    5s;

        proxy_cache ca;
        # Keyed on the request alone. The default key includes $proxy_host,
        # which is the *variable's* value here, so the whole cache would be
        # invalidated by renaming the upstream - exactly when the stale copies
        # are most wanted.
        proxy_cache_key "$scheme$request_uri";
        # pistis sends Cache-Control: max-age=300 and nginx honours it; these
        # are the fallback for a response that arrives without one.
        proxy_cache_valid 200 5m;
        proxy_cache_valid 404 1m;
        # Serve the last good copy when pistis, the tunnel or the name lookup
        # is unavailable, and refresh in the background so no client ever
        # waits for a revalidation. `error` is what covers a resolver failure.
        proxy_cache_use_stale error timeout updating
                              http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        # One request to the origin per key, however many arrive at once.
        proxy_cache_lock on;

        # Which is how you tell a served-stale CRL from a fresh one without
        # reading the logs: HIT, MISS, STALE, UPDATING or REVALIDATED.
        add_header X-Cache-Status $upstream_cache_status always;
    }

    # ------------------------------------------------------------------ /g2/
    # The CDP of the three certificates the root signed before G3 - serials
    # 1000-1002 in ca/rootca/index.txt, valid to December 2026, November 2029
    # and June 2035. One file, root.crl, installed from the repo clone by
    # install-ruby.sh; alias rather than root because the directory is
    # /var/www/ca.g2, not /var/www/g2.
    #
    # It is the same object as /g3/root.crl - one root, one CRL - but served
    # from a local copy rather than proxied, so the two CAN drift. They drift
    # only when the root CRL is regenerated (scripts/root-crl.sh, after a
    # revocation off the root), and install-ruby.sh asserts they still match.
    # Re-run it after any root-crl.sh.
    location /g2/ {
        alias /var/www/ca.g2/;
        autoindex off;
        default_type application/octet-stream;
        types {
            application/pkix-cert  crt;
            application/pkix-crl   crl;
            application/x-pem-file pem;
        }
        # A CRL that clients cache for a week is a revocation that takes a
        # week to land. Keep it short; the file is tiny.
        add_header Cache-Control "public, max-age=300";
    }

    # Reachability, for the blackbox probes and for ruling this vhost in or
    # out when /g3/ misbehaves. Answered here, not proxied: it says ruby is
    # serving the name, which is a different question from pistis being up.
    location = /healthz {
        access_log off;
        return 200 "ok\n";
    }

    # No index, no redirect to /g3/. pistis redirects / to /g3/ for the
    # convenience of someone poking at it on the LAN; on the public side the
    # only things that should be fetched are the frozen paths.
    location / {
        return 404;
    }
}
