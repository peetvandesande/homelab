# wordpress

sogode.com's WordPress on ruby: a container on `localhost:19080` behind ruby's
nginx. The vhost file also carries social.sogode.com, a static site whose
root is `/var/www/social.sogode.com`, and short links on sogode.com that
redirect to YouTube, Outlook bookings and documents under social's `/docs/`.

```
ruby/etc/nginx/sites-available/sogode.com   the vhost, as live on ruby
scripts/install-ruby.sh                     sudo ~/homelab/wordpress/scripts/install-ruby.sh
```

The file was taken from ruby on 30 October 2026. Since then: the login
restriction; social.sogode.com on IPv6, which its AAAA already promised; the
HTTP redirect keeps the path; uploads up to 500M; the short links restored
from the 3 August version; and the mta-sts and marketing server blocks
removed, as none of those names has a DNS record. Edit it here, not on ruby: the install replaces the live
file whole (showing the diff and keeping a dated backup), so a hand edit on
ruby is lost at the next install.

## Invariants

1. **Logging in needs the VPN.** `wp-login.php` and `xmlrpc.php` allow only
   `snippets/home-lan-allow.conf`. sogode.com resolves to ruby's public
   address everywhere, the home LAN included, so a browser at home arrives
   from the Orange address and is refused; on the road-warrior VPN it arrives
   from 192.168.204.0/24 and is let in.
2. **Jetpack is given up.** It talks to the site over XML-RPC – about a
   thousand calls a day before this – so closing XML-RPC disconnects it.
3. **The two restricted locations are nested in `location /`**, so they
   inherit its proxy headers. `proxy_pass` is not inherited and is repeated in
   each; change all three together.
