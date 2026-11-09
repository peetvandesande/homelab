#!/usr/bin/env python3
"""Move the lab's secrets between Bitwarden Secrets Manager and local files.

Bitwarden is the source of truth. ~/projects/homelab-private is a cache of it,
in the layout the deploy scripts already read. infra/secrets/manifest lists
what belongs where; this repo is public, so it holds names and never values.

  vault.py check     local only, needs no token: is the manifest satisfiable?
  vault.py import    copy local values up, then read each one back and compare
  vault.py verify    compare Bitwarden with the local files, writing nothing
  vault.py verify --dest DIR  the same, against a tree made by pull --dest
  vault.py pull      rebuild the local files from Bitwarden
  vault.py pull --dest DIR    the same, into an empty directory instead

Every command except check needs BWS_ACCESS_TOKEN in the environment. Output
is names only. `import` passes values to bws as arguments, because that is the
only way bws accepts them, so run it on a machine nobody else is logged in to.
"""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path
from typing import NamedTuple

REPO = Path(__file__).resolve().parents[2]
MANIFEST = REPO / "infra" / "secrets" / "manifest"
PRIVATE = Path(os.environ.get("HOMELAB_PRIVATE", Path.home() / "projects" / "homelab-private"))
MAX_VALUE = 25000  # the most bws will store in one secret
# What needs no quoting on the right of VAR=. Assignments are not subject to
# globbing or brace expansion, so * ? [ ] { } and ! are safe; a leading ~ is not.
SAFE_BARE = re.compile(r"(?!~)[A-Za-z0-9_@%+=:,./~^!*?\[\]{}-]*")


class Entry(NamedTuple):
    key: str
    project: str
    kind: str  # env: one variable in a file; env-bare: never quoted; file: a whole file
    path: str  # under homelab-private, or repo:<path under this repo>
    var: str


def die(message):
    sys.exit(f"vault: {message}")


def load_manifest(path):
    entries, seen = [], set()
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        if len(fields) != 5 or fields[2] not in ("env", "env-bare", "file"):
            die(f"{path.name}:{number}: expected: key project env|env-bare|file path variable-or-dash")
        entry = Entry(*fields)
        if entry.key in seen:
            die(f"{path.name}:{number}: {entry.key} is listed twice")
        seen.add(entry.key)
        entries.append(entry)
    return entries


def local_path(entry, base=None):
    if entry.path.startswith("repo:"):
        relative = entry.path[len("repo:"):]
        return base / "repo" / relative if base else REPO / relative
    return (base or PRIVATE) / entry.path


def parse_env(path):
    """The variables in a shell env file, without running it.

    Refuses anything whose meaning depends on the shell, because the value
    stored in Bitwarden has to be the value a script would actually have seen.
    """
    values = {}
    for line in path.read_bytes().decode().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)", line)
        if not match:
            raise ValueError("a line is not VAR=value")
        var, raw = match[1], match[2]
        if len(raw) >= 2 and raw[0] == raw[-1] == "'" and "'" not in raw[1:-1]:
            value = raw[1:-1]
        elif len(raw) >= 2 and raw[0] == raw[-1] == '"' and not re.search(r'[$`\\"]', raw[1:-1]):
            value = raw[1:-1]
        elif re.search(r"[\s$`\\'\"#]", raw):
            raise ValueError(f"{var} needs the shell to interpret it")
        else:
            value = raw
        values[var] = value
    return values


def render_env(triples):
    # Plain VAR=value wherever that is safe: some scripts read these with sed
    # rather than sourcing them, and would keep any quotes as part of the value.
    lines = [f"{var}={value if bare or SAFE_BARE.fullmatch(value) else shlex.quote(value)}"
             for var, value, bare in triples]
    return "\n".join(lines) + "\n"


class Local:
    """Values held in the local files, reading each file once."""

    def __init__(self, base=None):
        self.env = {}
        self.base = base

    def value(self, entry):
        path = local_path(entry, self.base)
        if entry.kind == "file":
            return path.read_bytes().decode()
        if path not in self.env:
            self.env[path] = parse_env(path)
        return self.env[path][entry.var]


class Bws:
    def __init__(self):
        if not os.environ.get("BWS_ACCESS_TOKEN"):
            die("BWS_ACCESS_TOKEN is not set")
        if not shutil.which("bws"):
            die("bws is not on PATH; run infra/scripts/install-bws.sh")

    def run(self, *args, hide=None):
        result = subprocess.run(["bws", *args], capture_output=True, text=True, timeout=120)
        if result.returncode:
            error = result.stderr.strip()
            if hide:
                error = error.replace(hide, "***")
            die(f"bws {args[0]} {args[1]} failed: {error[:200]}")
        return json.loads(result.stdout)

    def projects(self):
        return {p["name"]: p["id"] for p in self.run("project", "list", "--output", "json")}

    def secrets(self, project_id):
        found = defaultdict(list)
        for secret in self.run("secret", "list", project_id, "--output", "json"):
            found[secret["key"]].append(secret)
        return found

    def create(self, key, value, project_id):
        # The -- stops a value that begins with a dash being read as an option.
        self.run("secret", "create", "--output", "json", "--", key, value, project_id, hide=value)

    def edit(self, secret_id, value):
        self.run("secret", "edit", "--output", "json", f"--value={value}", secret_id, hide=value)


def remote_values(bws, entries):
    """Map manifest key to its Bitwarden secret, refusing ambiguity."""
    projects = bws.projects()
    wanted = sorted({e.project for e in entries})
    missing = [name for name in wanted if name not in projects]
    if missing:
        die(f"this token cannot see project(s): {', '.join(missing)}")
    listing = {name: bws.secrets(projects[name]) for name in wanted}
    found = {}
    for entry in entries:
        matches = listing[entry.project].get(entry.key, [])
        if len(matches) > 1:
            die(f"{entry.key} exists {len(matches)} times in {entry.project}; delete the extras")
        if matches:
            found[entry.key] = matches[0]
    return projects, found


def cmd_check(entries, _args):
    local, problems = Local(), 0
    claimed = set()
    for entry in entries:
        claimed.add(local_path(entry))
        try:
            value = local.value(entry)
        except (OSError, KeyError, ValueError) as error:
            detail = "not found" if isinstance(error, (OSError, KeyError)) else str(error)
            print(f"  PROBLEM {entry.key}: {detail}")
            problems += 1
            continue
        if not value:
            print(f"  PROBLEM {entry.key}: empty")
            problems += 1
        elif len(value) > MAX_VALUE:
            print(f"  PROBLEM {entry.key}: {len(value)} characters, over the limit of {MAX_VALUE}")
            problems += 1
        elif entry.kind == "env" and not SAFE_BARE.fullmatch(value):
            print(f"  note    {entry.key}: pull will write this single-quoted")
    print(f"{len(entries)} manifest entries, {problems} problem(s)")

    print("in homelab-private but not in the manifest:")
    for path in sorted(p for p in PRIVATE.rglob("*") if p.is_file() and p.name != ".DS_Store"):
        if path in claimed:
            continue
        relative = path.relative_to(PRIVATE)
        twin = REPO / relative
        same = twin.is_file() and twin.read_bytes() == path.read_bytes()
        state = "same as repo" if same else "differs from repo" if twin.is_file() else "only here"
        print(f"  {state:17} {relative}")
    return problems


def cmd_import(entries, _args):
    bws, local = Bws(), Local()
    projects, found = remote_values(bws, entries)
    created = updated = same = 0
    for entry in entries:
        value = local.value(entry)
        if entry.key not in found:
            bws.create(entry.key, value, projects[entry.project])
            print(f"  created   {entry.key}")
            created += 1
        elif found[entry.key]["value"] != value:
            bws.edit(found[entry.key]["id"], value)
            print(f"  updated   {entry.key}")
            updated += 1
        else:
            same += 1
    print(f"{created} created, {updated} updated, {same} already correct; reading back")
    return cmd_verify(entries, None)


def cmd_verify(entries, args):
    base = Path(args.dest).resolve() if args and args.dest else None
    bws, local = Bws(), Local(base)
    _, found = remote_values(bws, entries)
    bad = 0
    for entry in entries:
        if entry.key not in found:
            print(f"  MISSING   {entry.key}: not in Bitwarden")
            bad += 1
            continue
        try:
            if local.value(entry) != found[entry.key]["value"]:
                print(f"  DIFFERENT {entry.key}")
                bad += 1
        except (OSError, KeyError, ValueError):
            print(f"  NO LOCAL  {entry.key}")
            bad += 1
    print(f"{len(entries) - bad} of {len(entries)} match")
    return bad


def write_private(path, content):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    handle, temp = tempfile.mkstemp(dir=path.parent, prefix=".vault-")
    try:
        with os.fdopen(handle, "wb") as out:
            out.write(content.encode())
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    except BaseException:
        os.unlink(temp)
        raise


def cmd_pull(entries, args):
    base = Path(args.dest).resolve() if args.dest else None
    if base and base.exists() and any(base.iterdir()):
        die(f"{base} is not empty")
    bws = Bws()
    _, found = remote_values(bws, entries)
    absent = [e.key for e in entries if e.key not in found]
    if absent:
        die(f"not in Bitwarden, nothing written: {', '.join(absent)}")
    env_files = defaultdict(list)
    written = 0
    for entry in entries:
        value = found[entry.key]["value"]
        if entry.kind == "file":
            write_private(local_path(entry, base), value)
            written += 1
        else:
            env_files[local_path(entry, base)].append((entry.var, value, entry.kind == "env-bare"))
    for path, triples in env_files.items():
        write_private(path, render_env(triples))
        written += 1
    print(f"{written} files written, mode 600")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    commands = parser.add_subparsers(dest="command", required=True)
    for name, handler in (("check", cmd_check), ("import", cmd_import), ("verify", cmd_verify), ("pull", cmd_pull)):
        sub = commands.add_parser(name)
        sub.set_defaults(handler=handler)
        if name in ("pull", "verify"):
            sub.add_argument("--dest", help="use this directory instead of the real locations")
    args = parser.parse_args()
    sys.exit(1 if args.handler(load_manifest(args.manifest), args) else 0)


if __name__ == "__main__":
    main()
