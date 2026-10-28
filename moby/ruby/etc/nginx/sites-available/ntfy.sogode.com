# ntfy.sogode.com on ruby - the public face of ntfy in moby's jobsearch-shared
# stack. Managed in homelab/moby/ruby; installed by
# moby/scripts/install-ruby-ntfy.sh.
#
# Publicly a CNAME to this host. All of it is public: the phone app needs the
# API, and ntfy itself denies every topic to anyone without a login.

map $http_upgrade $ntfy_sogode_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name ntfy.sogode.com;

    access_log /var/log/nginx/ntfy.sogode.com.access.log;
    error_log  /var/log/nginx/ntfy.sogode.com.error.log;

    location / {
        return 308 https://ntfy.sogode.com$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ntfy.sogode.com;

    ssl_certificate     /etc/letsencrypt/live/ntfy.sogode.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/ntfy.sogode.com/privkey.pem;

    access_log /var/log/nginx/ntfy.sogode.com.access.log;
    error_log  /var/log/nginx/ntfy.sogode.com.error.log;

    client_max_body_size 2m;

    resolver 127.0.0.1 valid=30s;
    resolver_timeout 3s;
    set $moby moby.home;

    proxy_ssl_verify              on;
    proxy_ssl_trusted_certificate /etc/nginx/homelab-root-g2.crt;
    proxy_ssl_verify_depth        2;
    proxy_ssl_server_name         on;
    proxy_ssl_name                ntfy.sogode.com;

    # Not public, like every vhost install-ruby-vhost.sh puts here. ntfy's web
    # app answers 200 for any path, so close it explicitly.
    location = /metrics {
        return 404;
    }

    location / {
        proxy_pass https://$moby;
        proxy_http_version 1.1;
        proxy_set_header Host              ntfy.sogode.com;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $ntfy_sogode_connection_upgrade;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_connect_timeout 5s;
        proxy_read_timeout 3h;
    }
}
