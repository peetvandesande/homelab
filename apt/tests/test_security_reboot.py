"""Tests for homelab-security-reboot's conditions. Run: python3 -m unittest discover -s apt/tests"""
import datetime
import gzip
import importlib.machinery
import importlib.util
import os
import pathlib
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "root/usr/local/sbin/homelab-security-reboot"
loader = importlib.machinery.SourceFileLoader("security_reboot", str(SCRIPT))
spec = importlib.util.spec_from_loader("security_reboot", loader)
sr = importlib.util.module_from_spec(spec)
loader.exec_module(sr)


def paris(h, m=0):
    return datetime.datetime(2026, 11, 12, h, m, tzinfo=sr.PARIS).timestamp()


class Case(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        d = pathlib.Path(self.dir.name)
        self.d = d
        for name, value in (("REQUIRED", d / "reboot-required"),
                            ("DPKG_LOGS", str(d / "uu-dpkg.log*")),
                            ("STATE_DIR", d / "state"), ("PENDING", d / "state/pending.json")):
            p = mock.patch.object(sr, name, str(value))
            p.start()
            self.addCleanup(p.stop)
        self.addCleanup(self.dir.cleanup)

    def require(self, *pkgs):
        (self.d / "reboot-required").write_text("*** System restart required ***\n")
        (self.d / "reboot-required.pkgs").write_text("".join(f"{p}\n" for p in pkgs))

    def unattended(self, *pkgs, gz=False):
        text = "".join(f"Unpacking {p}:amd64 (1.0) ...\nSetting up {p} (1.0) ...\n" for p in pkgs)
        if gz:
            with gzip.open(self.d / "uu-dpkg.log.2.gz", "wt") as f:
                f.write(text)
        else:
            (self.d / "uu-dpkg.log").write_text(text)


class Reason(Case):
    def test_nothing_required(self):
        self.assertIsNone(sr.reboot_reason())

    def test_security_kernel(self):
        self.require("linux-image-6.12.116+deb13-cloud-amd64")
        self.unattended("linux-image-6.12.116+deb13-cloud-amd64")
        self.assertEqual(sr.reboot_reason(), ["linux-image-6.12.116+deb13-cloud-amd64"])

    def test_found_in_a_rotated_log(self):
        self.require("libc6")
        self.unattended("libc6", gz=True)
        self.assertEqual(sr.reboot_reason(), ["libc6"])

    def test_manual_upgrade_is_refused(self):
        self.require("proxmox-kernel-6.17", "libc6")
        self.unattended("libc6")
        with self.assertRaisesRegex(sr.Refused, "proxmox-kernel"):
            sr.reboot_reason()

    def test_unknown_cause_is_refused(self):
        (self.d / "reboot-required").write_text("")
        with self.assertRaises(sr.Refused):
            sr.reboot_reason()


class Window(unittest.TestCase):
    def test_inside_and_outside(self):
        with mock.patch.dict(sr.CONF, {"LATEST": "04:20"}):
            sr.check_window(paris(4, 0))
            for t in (paris(4, 21), paris(6), paris(23, 59)):
                with self.assertRaises(sr.Refused):
                    sr.check_window(t)


class PveBackup(Case):
    def prom(self, *ages, now):
        lines = [f'homelab_backup_last_success_timestamp_seconds{{vmid="{100 + i}",guest="g{i}"}} {now - a}\n'
                 for i, a in enumerate(ages)]
        p = self.d / "backup.prom"
        p.write_text("# HELP x\n" + "".join(lines))
        return str(p)

    def test_all_tonight(self):
        now = paris(4)
        with mock.patch.object(sr.subprocess, "run", return_value=mock.Mock(returncode=1)):
            sr.check_pve_backup(now, prom=self.prom(1800, 1500, now=now))

    def test_a_guest_missed(self):
        now = paris(4)
        with mock.patch.object(sr.subprocess, "run", return_value=mock.Mock(returncode=1)):
            with self.assertRaisesRegex(sr.Refused, "g1"):
                sr.check_pve_backup(now, prom=self.prom(1800, 30 * 3600, now=now))

    def test_backup_running(self):
        with mock.patch.object(sr.subprocess, "run", return_value=mock.Mock(returncode=0)):
            with self.assertRaisesRegex(sr.Refused, "still running"):
                sr.check_pve_backup(paris(4), prom="/nonexistent")


class OvhBackup(unittest.TestCase):
    def test_age(self):
        now = paris(4, 30)
        fresh = datetime.datetime.fromtimestamp(now - 3 * 3600, datetime.timezone.utc).isoformat()
        old = datetime.datetime.fromtimestamp(now - 40 * 3600, datetime.timezone.utc).isoformat()
        with mock.patch.dict(sr.CONF, {"OVH_SERVICE": "vps-x"}):
            with mock.patch.object(sr, "ovh_get", return_value=[old, fresh]):
                sr.check_ovh_backup(now)
            for points in ([old], []):
                with mock.patch.object(sr, "ovh_get", return_value=points), self.assertRaises(sr.Refused):
                    sr.check_ovh_backup(now)
            with mock.patch.object(sr, "ovh_get", side_effect=OSError("down")), self.assertRaises(sr.Refused):
                sr.check_ovh_backup(now)


class Check(Case):
    def run_check(self, mode, **conf):
        calls = []
        def action(*a):
            calls.append(a)
            return "abc123"
        env = {"MODE": mode, "LATEST": "05:00", "BACKUP": "ovh", "OVH_SERVICE": "vps-x", **conf}
        with mock.patch.dict(sr.CONF, env, clear=True), mock.patch.object(sr, "MODE", mode), \
             mock.patch.object(sr, "action", side_effect=action), \
             mock.patch.object(sr, "check_ovh_backup"), \
             mock.patch.object(sr.subprocess, "run") as run:
            sr.check(now=paris(4, 30))
        return calls, run

    def test_nothing_to_do_writes_nothing(self):
        calls, run = self.run_check("live")
        self.assertEqual(calls, [])
        run.assert_not_called()

    def test_shadow_records_and_does_not_reboot(self):
        self.require("libc6")
        self.unattended("libc6")
        calls, run = self.run_check("shadow")
        self.assertEqual([c[0] for c in calls], ["start", "end"])
        self.assertIn("shadow", calls[1])
        run.assert_not_called()

    def test_live_reboots_after_recording(self):
        self.require("libc6")
        self.unattended("libc6")
        calls, run = self.run_check("live")
        self.assertEqual([c[0] for c in calls], ["start"])
        run.assert_called_once_with(["systemctl", "reboot"], check=True)
        self.assertTrue(os.path.exists(sr.PENDING))

    def test_refusal_is_recorded(self):
        self.require("proxmox-kernel-6.17")
        calls, run = self.run_check("live")
        self.assertIn("refused", calls[1])
        run.assert_not_called()

    def test_no_action_log_no_reboot(self):
        self.require("libc6")
        self.unattended("libc6")
        with mock.patch.dict(sr.CONF, {"MODE": "live", "LATEST": "05:00", "BACKUP": "ovh"}, clear=True), \
             mock.patch.object(sr, "MODE", "live"), \
             mock.patch.object(sr, "action", side_effect=RuntimeError("journal")), \
             mock.patch.object(sr.subprocess, "run") as run, self.assertRaises(RuntimeError):
            sr.check(now=paris(4, 30))
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
