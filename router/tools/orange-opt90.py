#!/usr/bin/env python3
"""Build Orange's DHCPv4 option 90 / DHCPv6 option 11 authentication blob.

Reads ORANGE_LOGIN (fti/...) and ORANGE_PASSWORD from the environment, e.g.

    set -a; . ~/projects/homelab-private/router/orange.env; set +a
    ./orange-opt90.py

Prints the blob colon-separated, ready for `sendopts 0x5a:...` on wan; strip the
colons for `sendopts 11:...` on wan6. The salt is random, so every run differs.
"""
import hashlib
import os
import sys

try:
    login = os.environ["ORANGE_LOGIN"].encode()
    pwd = os.environ["ORANGE_PASSWORD"].encode()
except KeyError as e:
    sys.exit(f"{e.args[0]} not set")

salt, byte = os.urandom(16), os.urandom(1)
h = hashlib.md5(byte + pwd + salt).digest()
blob = (bytes(11) + bytes.fromhex("1a0900000558010341")
        + b"\x01" + bytes([len(login) + 2]) + login
        + b"\x3c\x12" + salt + b"\x03\x13" + byte + h)
print(":".join(f"{b:02x}" for b in blob))
