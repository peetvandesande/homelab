"""Tests for the runbook engine's matching. Run: python3 -m unittest discover -s runbooks/tests"""
import importlib.machinery
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1] / "root"
loader = importlib.machinery.SourceFileLoader("engine", str(ROOT / "usr/local/bin/runbook-engine"))
spec = importlib.util.spec_from_loader("engine", loader)
engine = importlib.util.module_from_spec(spec)
loader.exec_module(engine)

RULES = engine.load_rules(ROOT / "etc/runbook/rules.toml")


def failed_unit(instance="delphi.home:9100", name="rpz-update.service"):
    return {"alertname": "systemd unit failed", "instance": instance, "name": name}


class ShippedRules(unittest.TestCase):
    def test_every_rule_is_shadow(self):
        self.assertTrue(RULES)
        self.assertEqual({rule["mode"] for rule in RULES}, {"shadow"})


class Matching(unittest.TestCase):
    def test_allowed_unit(self):
        decision = engine.decide(RULES, failed_unit())
        self.assertTrue(decision["allowed"])
        self.assertEqual((decision["host"], decision["unit"]), ("delphi", "rpz-update.service"))

    def test_unlisted_alert_has_no_rule(self):
        self.assertIsNone(engine.decide(RULES, {"alertname": "Host down"}))

    def test_title_must_match_exactly(self):
        for name in ("systemd unit failed ", "SYSTEMD UNIT FAILED", "systemd unit failed; reboot"):
            self.assertIsNone(engine.decide(RULES, {"alertname": name}), name)

    def test_unit_on_the_wrong_host_is_refused(self):
        self.assertFalse(engine.decide(RULES, failed_unit("moby.home:9100"))["allowed"])

    def test_unlisted_unit_is_refused(self):
        self.assertFalse(engine.decide(RULES, failed_unit(name="sshd.service"))["allowed"])

    def test_disk_rule_leaves_out_the_ca_and_the_hypervisor(self):
        for host in ("pistis", "lenora", "ruby", "jennie"):
            labels = {"alertname": "Root filesystem nearly full", "instance": f"{host}.home:9100"}
            self.assertFalse(engine.decide(RULES, labels)["allowed"], host)

    def test_fixed_host_ignores_the_labels(self):
        labels = {"alertname": "Blocklist feed is stale", "instance": "moby.home:9100"}
        decision = engine.decide(RULES, labels)
        self.assertEqual((decision["host"], decision["unit"]), ("delphi", "rpz-update.service"))


class HostileInput(unittest.TestCase):
    def test_injection_in_the_unit_is_refused_and_cleaned(self):
        decision = engine.decide(RULES, failed_unit(name="rpz-update.service; rm -rf /"))
        self.assertFalse(decision["allowed"])
        self.assertNotIn(" ", decision["unit"])
        self.assertNotIn(";", decision["unit"])

    def test_injection_in_the_instance_is_refused(self):
        for instance in ("delphi.home:9100;reboot", "delphi.home:9100\n", "$(reboot).home:9100", "../delphi.home:9100"):
            decision = engine.decide(RULES, failed_unit(instance=instance))
            self.assertFalse(decision["allowed"], instance)
            self.assertRegex(decision["host"], r"^[A-Za-z0-9_.@:?-]*$")

    def test_long_values_are_truncated(self):
        decision = engine.decide(RULES, failed_unit(name="x" * 5000))
        self.assertLessEqual(len(decision["unit"]), 80)

    def test_labels_of_the_wrong_type(self):
        for value in (None, 7, ["x"], {"a": 1}):
            self.assertIsNone(engine.decide(RULES, {"alertname": value}))
            self.assertFalse(engine.decide(RULES, failed_unit(name=value))["allowed"])
            self.assertFalse(engine.decide(RULES, failed_unit(instance=value))["allowed"])

    def test_malformed_alerts_queue_nothing(self):
        for alerts in (None, "x", 7, [None], ["x"], [{"status": "firing"}], [{"status": "firing", "labels": "x"}]):
            self.assertEqual(engine.accept(RULES, alerts), 0, alerts)

    def test_resolved_alerts_queue_nothing(self):
        self.assertEqual(engine.accept(RULES, [{"status": "resolved", "labels": failed_unit()}]), 0)


class Validation(unittest.TestCase):
    def rule(self, **changes):
        rule = {"name": "a", "alert": "b", "runbook": "noop", "mode": "shadow", "host": "lexie"}
        rule.update(changes)
        return rule

    def test_a_good_rule_passes(self):
        engine.validate([self.rule()])

    def test_only_shadow_is_accepted(self):
        with self.assertRaises(ValueError):
            engine.validate([self.rule(mode="live")])

    def test_unknown_runbook(self):
        with self.assertRaises(ValueError):
            engine.validate([self.rule(runbook="rm-everything")])

    def test_two_rules_for_one_alert(self):
        with self.assertRaises(ValueError):
            engine.validate([self.rule(), self.rule(name="c")])

    def test_needs_exactly_one_target_kind(self):
        with self.assertRaises(ValueError):
            engine.validate([self.rule(hosts=["lexie"])])


if __name__ == "__main__":
    unittest.main()
