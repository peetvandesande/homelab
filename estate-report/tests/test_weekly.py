"""Tests for the weekly report. Run: python3 -m unittest discover -s estate-report/tests"""
import importlib.machinery
import importlib.util
import pathlib
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "lexie/usr/local/bin/estate-weekly"
loader = importlib.machinery.SourceFileLoader("weekly", str(SCRIPT))
spec = importlib.util.spec_from_loader("weekly", loader)
weekly = importlib.util.module_from_spec(spec)
loader.exec_module(weekly)


def ann(t, state, name, rule=1, **labels):
    text = ", ".join([f"alertname={name}"] + [f"{k}={v}" for k, v in labels.items()])
    return {"time": t * 1000, "newState": state, "alertName": name, "alertId": rule,
            "text": f"{name} {{{text}}} - A=1.000000"}


class Incidents(unittest.TestCase):
    def test_fired_and_resolved(self):
        eps = weekly.incidents([ann(100, "Pending", "Disk low", instance="moby"),
                                ann(160, "Alerting", "Disk low", instance="moby"),
                                ann(760, "Normal", "Disk low", instance="moby")], until=1000)
        (e,) = eps.values()
        self.assertEqual((e["fired"], e["seconds"], e["open"]), (1, 600, False))

    def test_still_firing_at_the_end(self):
        (e,) = weekly.incidents([ann(100, "Alerting", "Disk low")], until=400).values()
        self.assertEqual((e["seconds"], e["open"]), (300, True))

    def test_two_hosts_are_two_rows(self):
        eps = weekly.incidents([ann(1, "Alerting", "Disk low", instance="a"),
                                ann(1, "Alerting", "Disk low", instance="b")], until=10)
        self.assertEqual(len(eps), 2)

    def test_a_rule_renamed_mid_episode_resolves(self):
        eps = weekly.incidents([ann(100, "Alerting", "Old name", rule=7),
                                ann(200, "Normal (MissingSeries)", "New name", rule=7)], until=1000)
        (e,) = eps.values()
        self.assertEqual((e["alert"], e["seconds"], e["open"]), ("New name", 100, False))

    def test_heartbeat_and_pending_only_are_left_out(self):
        eps = weekly.incidents([ann(1, "Alerting", "Heartbeat"),
                                ann(1, "Pending", "Disk low"), ann(2, "Normal", "Disk low")], until=10)
        self.assertEqual(eps, {})


class Verdict(unittest.TestCase):
    def tearDown(self):
        weekly.issues.clear()

    def test_checks_decide(self):
        weekly.issues.append("something")
        self.assertEqual(weekly.verdict_line("smooth sailing"), "needs attention (1)")

    def test_claude_can_only_add_concern(self):
        self.assertEqual(weekly.verdict_line("needs attention"), "needs attention (Claude)")
        self.assertEqual(weekly.verdict_line("smooth sailing"), "smooth sailing")
        self.assertEqual(weekly.verdict_line(None), "smooth sailing")


class LokiPaging(unittest.TestCase):
    def test_lines_sharing_the_boundary_timestamp_are_neither_lost_nor_repeated(self):
        lines = [(10, "a"), (20, "b"), (20, "c"), (30, "d"), (40, "e")]

        def fake(url, params=None, **_):
            start = params["start"]
            page = [v for v in lines if v[0] >= start][:params["limit"]]
            return {"data": {"result": [{"stream": {}, "values": [[str(t), l] for t, l in page]}]}}

        real = weekly.get_json
        weekly.get_json = fake
        try:
            got = [l for _, _, l in weekly.loki_lines("{}", 0, 1e-6, page=2)]
        finally:
            weekly.get_json = real
        self.assertEqual(got, ["a", "b", "c", "d", "e"])


if __name__ == "__main__":
    unittest.main()
