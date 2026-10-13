#!/usr/bin/env python3
"""Fill key/PSK placeholders in the netplan and router configs in this directory.

Always fills what the local key files provide (wg1.key, wg2.key, *.pub, *.psk).
If the live wg-quick wg0.conf is piped in on stdin, also fills ruby's wg0 private
key and the PSKs of the existing peers (matched by public key):

    sudo cat /etc/wireguard.bak-2026-10-08/wg0.conf | ./fill-secrets.py

Secrets are never printed; only placeholder names are reported.

It fills files in place, so it refuses to run inside a git work tree: copy this
directory and the key files from ~/projects/homelab-private/wireguard to the
target host first (see CLAUDE.md).
"""
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
if any((d / ".git").exists() for d in (HERE, *HERE.parents)):
    sys.exit("refusing: inside a git work tree; copy this directory out first")
FILES = sorted([*HERE.glob("ruby/*.yaml"), *HERE.glob("jennie/*.yaml"), *HERE.glob("home/*.conf")])

# Placeholder -> local file holding the value
LOCAL = {
    "ruby wg1 private key": "wg1.key",
    "ruby wg1 public key": "wg1.pub",
    "ruby wg2 private key": "wg2.key",
    "ruby wg2 public key": "wg2.pub",
    "psk ruby-jennie": "jennie.psk",
    "psk home-jennie": "home-jennie.psk",
}

# Placeholder -> peer public key in the live wg0.conf
LIVE_PEERS = {
    "psk mba": "W7UWzForntjOHcJLzhyfTxFyBIlkOW6hv3Qeu1/4vDY=",
    "psk iphone-peet": "rp/DZg7hdcnVWpsQgR18K1Zg9DiCanwM1CDTw8l2DlE=",
    "psk mbp": "8mmp6Oocg9szzNW5uGCQRksRfOJ8385FFhedtv96czM=",
    "psk home": "vQww1GLubYz6J+77gFW9/2IbiShgx+E+peEuSX4VSVg=",
}

KEY_RE = re.compile(r"^[A-Za-z0-9+/]{43}=$")


def parse_live(text):
    values, peer = {}, None
    for line in text.splitlines():
        m = re.match(r"\s*(\w+)\s*=\s*(\S+)", line)
        if re.match(r"\s*(PreUp|PostUp|PreDown|PostDown)\s*=", line):
            print(f"live hook (check whether nftables.conf / wg-docker-user.service already covers it): {line.strip()}")
        if line.strip() == "[Peer]":
            peer = {}
        elif m and peer is None and m[1] == "PrivateKey":
            values["ruby wg0 private key"] = m[2]
        elif m and peer is not None:
            peer[m[1]] = m[2]
            if "PublicKey" in peer and "PreSharedKey" in peer:
                for name, pub in LIVE_PEERS.items():
                    if peer["PublicKey"] == pub:
                        values[name] = peer["PreSharedKey"]
    return values


values = {}
for name, fn in LOCAL.items():
    path = HERE / fn
    if path.exists():
        values[name] = path.read_text().strip()
if not sys.stdin.isatty():
    values.update(parse_live(sys.stdin.read()))

for name, value in values.items():
    if not KEY_RE.match(value):
        sys.exit(f"refusing: value for <{name}> does not look like a WireGuard key")

for path in FILES:
    text = new = path.read_text()
    for name, value in values.items():
        new = new.replace(f"<{name}>", value)
    if new != text:
        path.write_text(new)
        print(f"filled: {path.relative_to(HERE)}")

left = {(str(p.relative_to(HERE)), m) for p in FILES for m in re.findall(r"<([^>]+)>", p.read_text())}
for f, m in sorted(left):
    print(f"still to fill: {f}: <{m}>")
if not left:
    print("all placeholders filled")
