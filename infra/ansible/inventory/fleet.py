#!/usr/bin/env python3
"""Ansible inventory read from the FLEET array in ca/scripts/enrol.sh.

enrol.sh is the lab's existing list of hosts, so this reads it rather than
keeping another copy. Hosts are addressed by IP so that Ansible still works
when DNS is the thing that is broken.
"""
import json
import re
import sys
from pathlib import Path

ENROL = Path(__file__).resolve().parents[3] / "ca" / "scripts" / "enrol.sh"


def fleet():
    match = re.search(r"^FLEET=\((.*?)^\)", ENROL.read_text(), re.M | re.S)
    if not match:
        sys.exit(f"no FLEET array found in {ENROL}")
    hosts = {}
    for ip, name in re.findall(r'^\s*"(\d+\.\d+\.\d+\.\d+)\s+([^\s"]+)', match[1], re.M):
        hosts[name] = {"ansible_host": ip}
    if not hosts:
        sys.exit(f"FLEET in {ENROL} holds no hosts")
    return hosts


def main():
    hosts = fleet()
    if len(sys.argv) == 3 and sys.argv[1] == "--host":
        print(json.dumps(hosts.get(sys.argv[2], {})))
    else:
        print(json.dumps({
            "fleet": {"hosts": sorted(hosts)},
            "_meta": {"hostvars": hosts},
        }, indent=2))


if __name__ == "__main__":
    main()
