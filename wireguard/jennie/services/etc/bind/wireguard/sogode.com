; /etc/bind/wireguard/sogode.com
;
; Validate after every edit:
;   named-checkzone sogode.com /etc/bind/wireguard/sogode.com
;   rndc reload peetvandesande.com IN wireguard
;
; Bump the serial on every change. yyyymmddnn.

$ORIGIN sogode.com.
$TTL 300

@   IN  SOA vps-5ca50660.vps.ovh.net. hostmaster.peetvandesande.com. (
            2026111202  ; serial
            3600        ; refresh   (no secondary; value is inert)
            900         ; retry     (inert)
            604800      ; expire    (inert)
            60 )        ; negative cache TTL - keep low

    IN  NS  vps-5ca50660.vps.ovh.net.
@	60  IN  A       192.168.204.254
; The Sogode business n8n on moby, reached over the tunnel.
n8n	60  IN  A       192.168.8.27
n8n	60  IN  AAAA    fd33:5692:1834:1000:be24:11ff:fe13:54b8
; Forgejo, reached over the tunnel.
git	60  IN  A       192.168.8.62
git	60  IN  AAAA    fd33:5692:1834:1000:be24:11ff:fe14:eca4
; GLPI on glpi, reached over the tunnel.
itsm	60  IN  A       192.168.8.63
itsm	60  IN  AAAA    fd33:5692:1834:1000:be24:11ff:fe47:4c50
