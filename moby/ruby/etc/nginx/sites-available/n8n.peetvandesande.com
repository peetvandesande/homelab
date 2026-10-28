# n8n.peetvandesande.com on ruby - the public face of the n8n stack on moby.
# Managed in homelab/moby/ruby; installed by moby/scripts/install-ruby.sh.
#
# Publicly the name is a CNAME to this host. Inside the lab it is split-horizon
# and answers moby (dns/CLAUDE.md invariant 5), whose nginx fronts the stack.
#
# THE INTERNET GETS WEBHOOKS AND FORMS, NOT THE EDITOR. The editor and its API
# run arbitrary code on moby by design, so they are behind
# snippets/home-lan-allow.conf - home and VPN ranges - and everything else is
# 403. What is public is exactly what a third party has to reach: the webhook
# and form endpoints, and the static assets a form page loads.

map $http_upgrade $n8n_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name n8n.peetvandesande.com;

    access_log /var/log/nginx/n8n.peetvandesande.com.access.log;
    error_log  /var/log/nginx/n8n.peetvandesande.com.error.log;

    location / {
        return 308 https://n8n.peetvandesande.com$request_uri;
    }
}

server {
    # `listen ... http2`, not `http2 on;`, which nginx before 1.25.1 rejects.
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name n8n.peetvandesande.com;

    ssl_certificate     /etc/letsencrypt/live/n8n.peetvandesande.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/n8n.peetvandesande.com/privkey.pem;

    access_log /var/log/nginx/n8n.peetvandesande.com.access.log;
    error_log  /var/log/nginx/n8n.peetvandesande.com.error.log;

    client_max_body_size 16m;

    # Upstream, resolved per request for the reason ca.peetvandesande.com
    # gives: a name that fails at config load stops all of nginx. Both
    # families, as in git.peetvandesande.com.
    resolver 127.0.0.1 valid=30s;
    resolver_timeout 3s;
    set $moby moby.home;

    # moby's nginx serves a lab-CA certificate carrying this name.
    proxy_ssl_verify              on;
    proxy_ssl_trusted_certificate /etc/nginx/homelab-root-g2.crt;
    proxy_ssl_verify_depth        2;
    proxy_ssl_server_name         on;
    proxy_ssl_name                n8n.peetvandesande.com;

    proxy_set_header Host              n8n.peetvandesande.com;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_http_version 1.1;
    proxy_connect_timeout 5s;
    # A webhook can be configured to answer only when its workflow finishes.
    proxy_read_timeout    300s;

    location = /metrics {
        return 404;
    }

    # Public. Production and test webhooks, the resume URLs of Wait nodes,
    # forms, and the assets a form page pulls in.
    location ~ ^/(webhook|webhook-test|webhook-waiting|form|form-test|form-waiting|assets|static)/ {
        proxy_pass https://$moby;
        proxy_buffering off;
    }

    # Everything else is the editor, its REST API and the public API.
    location / {
        include snippets/home-lan-allow.conf;
        deny all;

        proxy_pass https://$moby;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $n8n_connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }
}
