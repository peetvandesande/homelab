#!/usr/bin/env python3
"""Certificate work for Home Assistant, run INSIDE the core container.

It lives here because the core container is the only place in HAOS with the
libraries for the job: there is no openssl and no step-cli anywhere on the
appliance, but `cryptography` and `requests` ship with Home Assistant.

Two constraints shape everything below:

  * /ssl is mounted READ-ONLY in the core container. Reading the current
    certificate and key is fine; writing is not. So this script only ever
    writes to /config, and the caller on lenora moves the result into /ssl
    from the HAOS host side, where it is writable.
  * The private key must never leave HAOS, the same rule the rest of the fleet
    follows. `csr` generates the key here and emits only a CSR. `renew` uses
    the key as a TLS client certificate, which is what it is for.

Commands:
  csr   --san NAME|IP ...   generate a new key + CSR (key -> .key.new)
  renew --expires-in-hours N  mTLS-renew if under N hours remain; else exit 3
  info                      print the installed certificate

Exit codes: 0 did the work, 3 nothing to do (renew not yet due), 1 error.
"""
import argparse
import datetime
import ipaddress
import json
import os
import sys

SSL = "/ssl"
OUT = "/config"
CRT = os.path.join(SSL, "homeassistant.crt")
KEY = os.path.join(SSL, "homeassistant.key")
ROOT = os.path.join(SSL, "root_ca.crt")
CA_URL = "https://192.168.8.55:8443"


def _san_objects(values):
    from cryptography import x509
    out = []
    for v in values:
        try:
            out.append(x509.IPAddress(ipaddress.ip_address(v)))
        except ValueError:
            out.append(x509.DNSName(v))
    return out


def cmd_csr(args):
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization, hashes
    from cryptography import x509
    from cryptography.x509.oid import NameOID

    key = ec.generate_private_key(ec.SECP256R1())
    keypath = os.path.join(OUT, "ha-tls.key.new")
    # 0600 from the moment it exists - it is written to /config, which the
    # caller moves into /ssl and then shreds here.
    fd = os.open(keypath, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM,
                                  serialization.PrivateFormat.PKCS8,
                                  serialization.NoEncryption()))

    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([
               x509.NameAttribute(NameOID.COMMON_NAME, args.subject)]))
           .add_extension(x509.SubjectAlternativeName(_san_objects(args.san)),
                          critical=False)
           .sign(key, hashes.SHA256()))
    with open(os.path.join(OUT, "ha-tls.csr"), "wb") as f:
        f.write(csr.public_bytes(serialization.Encoding.PEM))
    print("csr written for %s with SANs: %s" % (args.subject, ", ".join(args.san)))
    return 0


def _load_installed():
    from cryptography import x509
    with open(CRT, "rb") as f:
        return x509.load_pem_x509_certificate(f.read())


def cmd_renew(args):
    import requests

    if not os.path.exists(CRT) or not os.path.exists(KEY):
        print("no certificate installed at %s - run scripts/issue.sh" % CRT,
              file=sys.stderr)
        return 1

    cert = _load_installed()
    now = datetime.datetime.now(datetime.timezone.utc)
    left = cert.not_valid_after_utc - now
    hours = left.total_seconds() / 3600.0
    if hours < 0:
        # step-ca has allowRenewalAfterExpiry false, so this cannot be fixed by
        # renewing. Say so plainly rather than failing on a 401 from the CA.
        print("certificate expired %.1fh ago - renewal is refused after expiry, "
              "run scripts/issue.sh" % -hours, file=sys.stderr)
        return 1
    if hours > args.expires_in_hours:
        print("not due: %.1fh left, threshold %dh" % (hours, args.expires_in_hours))
        return 3

    # Verify the CA's own certificate against the lab root if we have it. The
    # root is installed into /ssl by issue.sh precisely so this is not a
    # verify=False call.
    verify = ROOT if os.path.exists(ROOT) else True
    r = requests.post(CA_URL + "/1.0/renew", cert=(CRT, KEY), verify=verify,
                      timeout=30)
    if r.status_code != 201:
        print("CA returned %d: %s" % (r.status_code, r.text[:300]), file=sys.stderr)
        return 1

    body = r.json()
    chain = body.get("certChain")
    if isinstance(chain, list) and chain:
        # [leaf, intermediate] - exactly the bundle Home Assistant wants, and
        # the same shape `step ca sign` produces for the rest of the fleet.
        fullchain = "".join(chain)
    else:
        fullchain = body.get("crt", "") + body.get("ca", "")
    if fullchain.count("BEGIN CERTIFICATE") < 2:
        print("CA response did not contain a leaf and an intermediate",
              file=sys.stderr)
        return 1

    # Cheap insurance: a certificate that does not match the installed key
    # would leave Home Assistant refusing to start, and HA is the thing we
    # would then need in order to fix it. The renew endpoint returns a cert for
    # the same key by construction, so this should never fire - which is
    # exactly why it is worth asserting rather than assuming.
    from cryptography.hazmat.primitives import serialization
    from cryptography import x509
    leaf = x509.load_pem_x509_certificate(fullchain.encode())
    with open(KEY, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    pub = lambda k: k.public_bytes(serialization.Encoding.PEM,
                                   serialization.PublicFormat.SubjectPublicKeyInfo)
    if pub(leaf.public_key()) != pub(key.public_key()):
        print("renewed certificate does not match the installed key - refusing "
              "to stage it", file=sys.stderr)
        return 1

    with open(os.path.join(OUT, "ha-tls.crt.new"), "w") as f:
        f.write(fullchain)
    print("renewed: %.1fh were left; new certificate staged (expires %s)"
          % (hours, leaf.not_valid_after_utc.isoformat()))
    return 0


def cmd_info(args):
    cert = _load_installed()
    from cryptography import x509
    try:
        sans = cert.extensions.get_extension_for_class(
            x509.SubjectAlternativeName).value
        san_s = ", ".join(str(g.value) for g in sans)
    except x509.ExtensionNotFound:
        san_s = "(none)"
    print(json.dumps({
        "subject": cert.subject.rfc4514_string(),
        "issuer": cert.issuer.rfc4514_string(),
        "not_after": cert.not_valid_after_utc.isoformat(),
        "sans": san_s,
    }, indent=2))
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("csr")
    c.add_argument("--subject", default="homeassistant.home")
    c.add_argument("--san", action="append", required=True)
    c.set_defaults(func=cmd_csr)

    r = sub.add_parser("renew")
    r.add_argument("--expires-in-hours", type=int, default=240)
    r.set_defaults(func=cmd_renew)

    i = sub.add_parser("info")
    i.set_defaults(func=cmd_info)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
