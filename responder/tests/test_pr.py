"""Tests for responder-pr's refusals. Run: python3 -m unittest discover -s responder/tests"""
import importlib.machinery
import importlib.util
import os
import pathlib
import subprocess
import tempfile
import unittest

os.environ.setdefault("FORGEJO_TOKEN", "test")
os.environ.setdefault("RESPONDER_HA_URL", "https://example.invalid/")
SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "root/usr/local/bin/responder-pr"
loader = importlib.machinery.SourceFileLoader("responder_pr", str(SCRIPT))
spec = importlib.util.spec_from_loader("responder_pr", loader)
pr = importlib.util.module_from_spec(spec)
loader.exec_module(pr)

Z40 = "0" * 40


def raw(*entries):
    """`git diff --raw -z` for (new mode, path) pairs."""
    return "".join(f":100644 {m} {Z40} {Z40} M\0{p}\0" for m, p in entries)


class Paths(unittest.TestCase):
    def test_ordinary_change(self):
        self.assertEqual(pr.checked_paths(raw(("100644", "alloy/root/etc/alloy/config.alloy"))),
                         ["alloy/root/etc/alloy/config.alloy"])

    def test_denied(self):
        for path in (".forgejo/workflows/checks.yml", "infra/scripts/apply.sh",
                     ".gitleaks.toml", "dns/.gitignore", "moby/.gitattributes",
                     "dns/secrets.env", "ca/intermediate/private/x.key"):
            with self.subTest(path=path), self.assertRaises(pr.Refused):
                pr.checked_paths(raw(("100644", path)))

    def test_symlinks_and_submodules(self):
        for mode in ("120000", "160000"):
            with self.subTest(mode=mode), self.assertRaises(pr.Refused):
                pr.checked_paths(raw((mode, "fleet/link")))

    def test_too_many_files_or_none(self):
        with self.assertRaises(pr.Refused):
            pr.checked_paths(raw(*[("100644", f"a/{i}") for i in range(pr.MAX_FILES + 1)]))
        with self.assertRaises(pr.Refused):
            pr.checked_paths("")


class Diff(unittest.TestCase):
    def test_takes_the_last_block(self):
        report = "```diff\nfirst\n```\ntext\n```diff\nsecond\n```\nVERDICT: action-needed"
        self.assertEqual(pr.DIFF.findall(report)[-1], "second\n")

    def test_real_raw_output_parses(self):
        """checked_paths reads what git actually prints, renames split in two."""
        with tempfile.TemporaryDirectory() as d:
            g = lambda *a: subprocess.run(["git", "-C", d, *a], check=True,
                                          capture_output=True, text=True).stdout
            g("init", "-q")
            pathlib.Path(d, "a.txt").write_text("x\n")
            g("add", "a.txt")
            g("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "a")
            g("mv", "a.txt", "b.txt")
            pathlib.Path(d, "c.txt").write_text("y\n")
            g("add", "c.txt")
            out = g("diff", "--cached", "--raw", "-z", "--no-renames")
            self.assertEqual(sorted(pr.checked_paths(out)), ["a.txt", "b.txt", "c.txt"])


if __name__ == "__main__":
    unittest.main()
