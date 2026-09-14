#!/usr/bin/env python3
"""Resolve a name over DoT and print the A record.

Exists because macOS dig is 9.10 and has no +tls, and kdig is not installed.
Hand-rolled rather than depending on dnspython so verify.sh has no install step.

  dns-tls-query.py dot <ip> <port> <name> <ca-file> [server-name]

DoT only, deliberately. dnsdist's DoH frontend advertises ALPN **h2 and nothing
else**, so an HTTP/1.1 request - all the standard library can produce - is
answered with a bare 400. verify.sh tests DoH with `curl --doh-url` instead,
which negotiates HTTP/2 and, as a bonus, exercises the full path: resolve an
internal name over DoH, then connect to it and validate its certificate.

Exits non-zero on anything other than a NOERROR answer containing an A record.
"""
import socket, ssl, struct, sys


def query(name):
    """A minimal A/IN query. ID 0 is fine: one query per connection."""
    q = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00"
    return struct.pack("!HHHHHH", 0, 0x0100, 1, 0, 0, 0) + q + struct.pack("!HH", 1, 1)


def parse(resp):
    """Return the first A record as a dotted quad, or raise."""
    (_, flags, qd, an, _, _) = struct.unpack("!HHHHHH", resp[:12])
    rcode = flags & 0xF
    if rcode:
        raise SystemExit(f"RCODE {rcode}")
    if not an:
        raise SystemExit("no answer records")
    off = 12
    for _ in range(qd):                       # skip the question
        while resp[off]:
            off += resp[off] + 1
        off += 5                              # null label + qtype + qclass
    for _ in range(an):
        if resp[off] & 0xC0 == 0xC0:          # compression pointer
            off += 2
        else:
            while resp[off]:
                off += resp[off] + 1
            off += 1
        rtype, _, _, rdlen = struct.unpack("!HHIH", resp[off:off + 10])
        off += 10
        if rtype == 1 and rdlen == 4:
            return ".".join(str(b) for b in resp[off:off + 4])
        off += rdlen
    raise SystemExit("no A record in answer")


def main():
    mode, ip, port, name, ca = sys.argv[1:6]
    # The certificate is issued to a .home name that nothing resolves yet, so
    # the caller says which name to verify against; default to the IP, which
    # every lab certificate carries as a SAN.
    server_name = sys.argv[6] if len(sys.argv) > 6 else ip
    ctx = ssl.create_default_context(cafile=ca)

    if mode == "dot":
        with socket.create_connection((ip, int(port)), timeout=8) as raw:
            with ctx.wrap_socket(raw, server_hostname=server_name) as tls:
                msg = query(name)
                tls.sendall(struct.pack("!H", len(msg)) + msg)   # DoT length prefix
                n = struct.unpack("!H", tls.recv(2))[0]
                print(parse(tls.recv(n)))
    else:
        raise SystemExit("mode must be dot")


main()
