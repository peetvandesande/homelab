"""Tests for the weekly report. Run: python3 -m unittest discover -s estate-report/tests"""
import importlib.machinery
import importlib.util
import os
import pathlib
import tempfile
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
        weekly.issue("something")
        self.assertEqual(weekly.verdict_line("smooth sailing"), "needs attention (1)")

    def test_the_subject_counts_what_is_under_investigation(self):
        weekly.issue("a")
        weekly.issue("b")
        weekly.issues[0]["status"] = "runbook x; under investigation"
        self.assertEqual(weekly.verdict_line(None), "needs attention (2, 1 under investigation)")

    def test_claude_can_only_add_concern(self):
        self.assertEqual(weekly.verdict_line("needs attention"), "needs attention (Claude)")
        self.assertEqual(weekly.verdict_line("smooth sailing"), "smooth sailing")
        self.assertEqual(weekly.verdict_line(None), "smooth sailing")


class FollowUp(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        rules = os.path.join(self.dir.name, "rules.toml")
        with open(rules, "w") as f:
            f.write('[[rule]]\nname = "free-disk"\nalert = "Root filesystem nearly full"\n')
        self.saved = dict(weekly.CONF)
        weekly.CONF.update(RUNBOOK_RULES=rules, STATE=os.path.join(self.dir.name, "s", "state.json"),
                           RESPONDER_URL="responder", RUNBOOK_URL="runbook")
        self.posted = []
        self.real = weekly.post_alert
        self.reply = 1

        def fake(url, token, alert):
            if self.reply is None:
                raise OSError("down")
            self.posted.append((url, alert))
            return self.reply
        weekly.post_alert = fake

    def tearDown(self):
        weekly.post_alert = self.real
        weekly.CONF.clear()
        weekly.CONF.update(self.saved)
        weekly.issues.clear()
        self.dir.cleanup()

    def items(self, *texts, section=None, **kw):
        """Issues each in its own section, or all in `section`."""
        weekly.issues.clear()
        for n, t in enumerate(texts):
            weekly.section = section or f"s{n}"
            weekly.issue(t, **kw)
        return list(weekly.issues)

    def test_keys_survive_changing_numbers(self):
        self.assertEqual(weekly.issue_key("moby: root filesystem 91% full"),
                         weekly.issue_key("moby: root filesystem 87% full"))
        self.assertNotEqual(weekly.issue_key("moby: root filesystem 91% full"),
                            weekly.issue_key("loki: root filesystem 91% full"))
        self.assertEqual(weekly.issue_key("scrape job n8n: up 94.7% of the week"),
                         "scrape job n8n: up N% of the week")

    def test_at_most_three_are_investigated_in_order(self):
        items = weekly.follow_up(self.items("a", "b", "c", "d"), now=1000)
        self.assertEqual([i["status"] for i in items][:3], ["under investigation"] * 3)
        self.assertTrue(items[3]["status"].startswith("open – over"))
        self.assertEqual([a["annotations"]["summary"] for _, a in self.posted], ["- a", "- b", "- c"])

    def test_one_section_is_one_investigation(self):
        items = weekly.follow_up(self.items("n8n down", "probe n8n failing", section="hosts"), now=1000)
        self.assertEqual([i["status"] for i in items], ["under investigation (with 1 more from hosts)"] * 2)
        (_, alert), = self.posted
        self.assertEqual(alert["annotations"]["summary"], "- n8n down\n- probe n8n failing")
        self.assertEqual(alert["labels"]["key"], "hosts: n8n down and 1 more")

    def test_a_runbook_match_goes_to_the_engine_and_is_investigated_too(self):
        (i,) = weekly.follow_up(self.items("moby: root filesystem 91% full",
                                           alert="Root filesystem nearly full",
                                           labels={"instance": "moby.home:9100"}), now=1000)
        self.assertEqual(i["status"], "runbook free-disk; under investigation")
        url, alert = self.posted[0]
        self.assertEqual((url, alert["labels"]["alertname"], alert["labels"]["instance"]),
                         ("runbook", "Root filesystem nearly full", "moby.home:9100"))
        self.assertEqual(self.posted[1][1]["labels"], {"alertname": "Weekly report", "key": f"s0: {i['key']}"})

    def test_one_sent_recently_is_not_sent_again(self):
        weekly.follow_up(self.items("a"), now=1000)
        (i,) = weekly.follow_up(self.items("a"), now=1000 + 3600)
        self.assertTrue(i["status"].startswith("under investigation since"))
        (i,) = weekly.follow_up(self.items("a"), now=1000 + 86400)
        self.assertTrue(i["status"].startswith("investigated "))
        (i,) = weekly.follow_up(self.items("a"), now=1000 + 7 * 86400)
        self.assertEqual(i["status"], "under investigation")
        self.assertEqual(len(self.posted), 2)

    def test_a_declined_or_unreachable_responder_leaves_it_open(self):
        self.reply = 0
        (i,) = weekly.follow_up(self.items("a"), now=1000)
        self.assertEqual(i["status"], "open – the responder did not take it")
        self.reply = None
        (i,) = weekly.follow_up(self.items("a"), now=1000)
        self.assertTrue(i["status"].startswith("open – the responder was not reached"))

    def test_a_shared_status_is_written_once(self):
        items = weekly.follow_up(self.items("a", "b", section="hosts") + [], now=1000)
        self.assertEqual(weekly.issue_lines(items),
                         ["  ✗ a", "  ✗ b", "      → under investigation (with 1 more from hosts)"])

    def test_a_dry_run_sends_nothing_and_remembers_nothing(self):
        (i,) = weekly.follow_up(self.items("a"), now=1000, send=False)
        self.assertEqual(i["status"], "open – would be investigated")
        self.assertEqual(self.posted, [])
        self.assertFalse(os.path.exists(weekly.CONF["STATE"]))


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
