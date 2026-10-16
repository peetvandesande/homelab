; /etc/bind/wireguard/mail.peetvandesande.com
;
; Validate after every edit:
;   named-checkzone mail.peetvandesande.com /etc/bind/wireguard/mail.peetvandesande.com
;   rndc reload peetvandesande.com IN wireguard
;
; Bump the serial on every change. yyyymmddnn.

$ORIGIN mail.peetvandesande.com.
$TTL 300

@   IN  SOA vps-5ca50660.vps.ovh.net. hostmaster.peetvandesande.com. (
            2026101601  ; serial
            3600        ; refresh   (no secondary; value is inert)
            900         ; retry     (inert)
            604800      ; expire    (inert)
            60 )        ; negative cache TTL - keep low

    IN  NS  vps-5ca50660.vps.ovh.net.
@	60  IN  A       192.168.204.254
@	60  IN  AAAA    fd33:5692:1834:204::254
