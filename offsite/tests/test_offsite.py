"""Tests for the off-site script's lock renewal. Run: python3 -m unittest discover -s offsite/tests"""
import datetime as dt
import importlib.machinery
import importlib.util
import pathlib
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "root/usr/local/sbin/offsite"
loader = importlib.machinery.SourceFileLoader("offsite", str(SCRIPT))
spec = importlib.util.spec_from_loader("offsite", loader)
offsite = importlib.util.module_from_spec(spec)
loader.exec_module(offsite)

NOW = dt.datetime.now(dt.timezone.utc)


class FakeBucket:
    """list_object_versions, get/put_object_retention, and compliance mode's one rule."""

    def __init__(self, objects):
        self.objects = objects  # (key, version, latest, size, days left)
        self.until = {(k, v): NOW + dt.timedelta(days=d) for k, v, _, _, d in objects}
        self.puts = []

    def get_paginator(self, _name):
        bucket = self

        class Pages:
            def paginate(self, **_):
                yield {"Versions": [{"Key": k, "VersionId": v, "IsLatest": latest, "Size": size,
                                     "LastModified": NOW} for k, v, latest, size, _ in bucket.objects],
                       "DeleteMarkers": [{"Key": "gone", "VersionId": "m", "LastModified": NOW}]}
        return Pages()

    def get_object_retention(self, Bucket, Key, VersionId):
        return {"Retention": {"Mode": "COMPLIANCE", "RetainUntilDate": self.until[(Key, VersionId)]}}

    def put_object_retention(self, Bucket, Key, VersionId, Retention):
        new = Retention["RetainUntilDate"]
        if new < self.until[(Key, VersionId)]:
            raise AssertionError("compliance mode refuses a shorter lock")
        self.until[(Key, VersionId)] = new
        self.puts.append(Key)


class RenewLocks(unittest.TestCase):
    def test_renews_only_current_versions_running_short(self):
        bucket = FakeBucket([
            ("data/a", "1", True, 100, 10),    # current, nearly expired: renew
            ("data/b", "1", True, 200, 85),    # current, plenty left: leave
            ("data/c", "1", False, 300, 10),   # deleted by restic: let it expire
        ])
        stored, objects, soonest = offsite.renew_locks(bucket, "b")
        self.assertEqual(bucket.puts, ["data/a"])
        self.assertEqual((stored, objects), (600, 3))
        self.assertGreater(bucket.until[("data/a", "1")], NOW + dt.timedelta(days=89))
        self.assertGreater(soonest, NOW + dt.timedelta(days=offsite.RENEW_DAYS))

    def test_every_current_version_ends_above_the_floor(self):
        bucket = FakeBucket([(f"k{d}", "1", True, 1, d) for d in range(0, 91, 5)])
        offsite.renew_locks(bucket, "b")
        floor = NOW + dt.timedelta(days=offsite.RENEW_DAYS)
        self.assertTrue(all(until >= floor for until in bucket.until.values()))


class Timestamps(unittest.TestCase):
    def test_nanoseconds_and_zones(self):
        self.assertEqual(offsite.whole_seconds("2026-11-10T10:00:00.123456789+01:00"),
                         int(dt.datetime(2026, 11, 10, 9, tzinfo=dt.timezone.utc).timestamp()))
        self.assertEqual(offsite.whole_seconds("2026-11-10T09:00:00Z"),
                         int(dt.datetime(2026, 11, 10, 9, tzinfo=dt.timezone.utc).timestamp()))


if __name__ == "__main__":
    unittest.main()
