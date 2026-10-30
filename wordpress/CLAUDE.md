# wordpress

sogode.com's WordPress on ruby: a container on `localhost:19080` behind ruby's
nginx. The vhost (`/etc/nginx/sites-available/sogode.com` on ruby) is
hand-managed and not in this repo; what is here is the one part of it the repo
owns.

```
ruby/etc/nginx/snippets/sogode-wordpress-private.conf   wp-login.php and xmlrpc.php: home and VPN only
scripts/install-ruby.sh                                 sudo ~/homelab/wordpress/scripts/install-ruby.sh
```

## Invariants

1. **Logging in needs the VPN.** The allow list is
   `snippets/home-lan-allow.conf`. sogode.com resolves to ruby's public
   address everywhere, including the home LAN, so a browser at home arrives
   from the Orange address and is refused; on the road-warrior VPN it arrives
   from 192.168.204.0/24 and is let in.
2. **Jetpack is given up.** It talks to the site over XML-RPC – about a
   thousand calls a day before this – so closing XML-RPC disconnects it.
3. **The snippet is included inside `location /`**, so its nested locations
   inherit the proxy headers there. `install-ruby.sh` puts it right after
   that location's `proxy_pass` and refuses if there is not exactly one.
