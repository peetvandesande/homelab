; /etc/bind/wireguard/git.peetvandesande.com
;
; VPN clients get the lab's answer, as the LAN does (dns/ansible, the
; split-horizon zone of the same name): forgejo directly over the
; tunnel, rather than ruby's public address and its public vhost. Same
; addresses as the LAN's copy - change both together.
;
; Validate after every edit:
;   named-checkzone git.peetvandesande.com /etc/bind/wireguard/git.peetvandesande.com
;   rndc reload git.peetvandesande.com IN wireguard     (on jennie: rndc reload git.peetvandesande.com)
;
; Bump the serial on every change. yyyymmddnn.

$ORIGIN git.peetvandesande.com.
$TTL 300

@   IN  SOA vps-5ca50660.vps.ovh.net. hostmaster.peetvandesande.com. (
            2026102801  ; serial
            3600        ; refresh   (no secondary; value is inert)
            900         ; retry     (inert)
            604800      ; expire    (inert)
            60 )        ; negative cache TTL - keep low

    IN  NS  vps-5ca50660.vps.ovh.net.
@	60  IN  A       192.168.8.62
@	60  IN  AAAA    fd33:5692:1834:1000:be24:11ff:fe14:eca4
