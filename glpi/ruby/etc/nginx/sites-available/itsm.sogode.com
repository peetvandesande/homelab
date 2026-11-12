# itsm.sogode.com on ruby - the public face of GLPI on glpi. Managed in
# homelab/glpi/ruby; installed by infra/ansible/outside.yml.
#
# Publicly the name is an A/AAAA to this host (not a CNAME: it also carries the
# MX and SPF of its mail domain, hosted here); inside the lab and the VPN it
# resolves to glpi itself, whose nginx serves a lab-CA certificate carrying
# this name.
#
# THE INTERNET GETS NOTHING BUT A 403. GLPI is for the lab, so everything is
# behind snippets/home-lan-allow.conf - home and VPN ranges. The one exception
# is status.php for jennie's prober, which proves the whole path - ruby, wg1,
# glpi and its database - from outside.

server {
    listen 80;
    listen [::]:80;
    server_name itsm.sogode.com;

    access_log /var/log/nginx/itsm.sogode.com.access.log;
    error_log  /var/log/nginx/itsm.sogode.com.error.log;

    # certbot's nginx plugin answers http-01 by injecting its own location for
    # the duration of the challenge; everything else goes to HTTPS.
    location / {
        return 308 https://itsm.sogode.com$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name itsm.sogode.com;

    ssl_certificate     /etc/letsencrypt/live/itsm.sogode.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/itsm.sogode.com/privkey.pem;

    access_log /var/log/nginx/itsm.sogode.com.access.log;
    error_log  /var/log/nginx/itsm.sogode.com.error.log;

    # Ticket attachments; glpi's own nginx and PHP allow the same.
    client_max_body_size 100m;

    # Upstream, resolved per request: a name that fails at config load stops
    # all of nginx. 127.0.0.1 is this host's named, which resolves home. for
    # both families.
    resolver 127.0.0.1 valid=30s;
    resolver_timeout 3s;
    set $glpi glpi.home;

    # glpi's nginx serves a lab-CA certificate carrying this name.
    proxy_ssl_verify              on;
    proxy_ssl_trusted_certificate /etc/nginx/homelab-root-g2.crt;
    proxy_ssl_verify_depth        2;
    proxy_ssl_server_name         on;
    proxy_ssl_name                itsm.sogode.com;

    proxy_set_header Host              itsm.sogode.com;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_http_version 1.1;
    proxy_connect_timeout 5s;
    proxy_read_timeout    300s;

    # jennie's blackbox exporter, by its public addresses.
    location = /status.php {
        allow 57.129.180.73;
        allow 2001:41d0:801:2000::180f;
        include snippets/home-lan-allow.conf;
        deny all;

        proxy_pass https://$glpi;
    }

    location / {
        include snippets/home-lan-allow.conf;
        deny all;

        proxy_pass https://$glpi;
    }
}
