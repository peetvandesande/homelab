# git.peetvandesande.com on ruby - the public face of Forgejo. Managed in
# homelab/forgejo/ruby; installed by forgejo/scripts/install-ruby.sh.
#
# Publicly the name is a CNAME to this host. Inside the lab it is split-horizon
# and answers forgejo itself (dns/CLAUDE.md invariant 5), so this vhost is the
# path for everyone off the LAN and nobody on it.
#
# Proxied, not cached: Forgejo is the single origin. When wgclient1 or home is
# down this answers 502, which is the truth.
#
# git over SSH does not come through here: ruby's public :22 is a stream
# proxy to forgejo (stream.d/), installed by forgejo/scripts/install-ruby-ssh.sh.

server {
    listen 80;
    listen [::]:80;
    server_name git.peetvandesande.com;

    access_log /var/log/nginx/git.peetvandesande.com.access.log;
    error_log  /var/log/nginx/git.peetvandesande.com.error.log;

    # certbot's nginx plugin answers http-01 by injecting its own location for
    # the duration of the challenge; everything else goes to HTTPS.
    location / {
        return 308 https://git.peetvandesande.com$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name git.peetvandesande.com;

    ssl_certificate     /etc/letsencrypt/live/git.peetvandesande.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/git.peetvandesande.com/privkey.pem;

    # Named for the vhost in full, as ca.peetvandesande.com explains.
    access_log /var/log/nginx/git.peetvandesande.com.access.log;
    error_log  /var/log/nginx/git.peetvandesande.com.error.log;

    # Pushes and LFS objects come through here. Forgejo enforces its own
    # limits; nginx's 1m default would refuse an ordinary push.
    client_max_body_size 1g;

    # Open on the LAN for Prometheus, never from outside.
    location = /metrics {
        return 404;
    }

    location / {
        # RESOLVED AT RUNTIME, NOT AT CONFIG LOAD - the same reasoning as /g3/
        # in ca.peetvandesande.com. A literal name in proxy_pass is resolved
        # once when nginx starts, and a failure is fatal: nginx does not start,
        # and sogode.com and webmail go with it. Through a variable it is a 502
        # on this vhost alone.
        #
        # 127.0.0.1 is this host's named, with a `home` static-stub to Pythia in
        # its internal view. Both families: forgejo.home carries a ULA AAAA, and
        # fd33:5692:1834:1000::/64 is in wg1's AllowedIPs. If one family is
        # broken nginx moves on to the other address after the connect timeout.
        resolver 127.0.0.1 valid=30s;
        resolver_timeout 3s;
        set $forgejo forgejo.home;
        proxy_pass https://$forgejo;

        # Forgejo serves a lab-CA certificate that carries this name. Verify it
        # against the lab root rather than turning verification off: this hop
        # crosses the tunnel and the home router.
        proxy_ssl_verify              on;
        proxy_ssl_trusted_certificate /etc/nginx/homelab-root-g2.crt;
        proxy_ssl_verify_depth        2;
        proxy_ssl_server_name         on;
        proxy_ssl_name                git.peetvandesande.com;

        proxy_set_header Host              git.peetvandesande.com;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_http_version 1.1;

        # Stream git traffic both ways rather than spooling it to disk here.
        proxy_request_buffering off;
        proxy_buffering         off;
        proxy_connect_timeout   5s;
        proxy_read_timeout      600s;
        proxy_send_timeout      600s;
    }
}
