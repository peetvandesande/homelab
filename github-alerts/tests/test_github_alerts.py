import importlib.machinery
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

PATH = Path(__file__).resolve().parents[1] / "root/usr/local/bin/github-alerts"
loader = importlib.machinery.SourceFileLoader("github_alerts", str(PATH))
spec = importlib.util.spec_from_loader("github_alerts", loader)
ga = importlib.util.module_from_spec(spec)
loader.exec_module(ga)


def alert(n, sev="high", path="a.py", line=3, desc='Uses "eval"'):
    return {"number": n, "html_url": f"https://github.com/x/y/security/code-scanning/{n}",
            "rule": {"id": "py/eval", "security_severity_level": sev, "severity": "error",
                     "description": desc},
            "tool": {"name": "CodeQL"},
            "most_recent_instance": {"location": {"path": path, "start_line": line},
                                     "message": {"text": "m"}}}


class Render(unittest.TestCase):
    def test_one_series_per_alert_with_its_place(self):
        out = ga.render([alert(2), alert(1, path="b.py", line=9)], 1000)
        series = [l for l in out.splitlines() if l.startswith("github_code_scanning_alert{")]
        self.assertEqual(len(series), 2)
        self.assertIn('number="1"', series[0])
        self.assertIn('path="b.py",line="9"', series[0])

    def test_counts_every_severity_even_at_zero(self):
        out = ga.render([alert(1), alert(2, sev=None)], 1000)
        self.assertIn('github_code_scanning_alerts_open{severity="high"} 1', out)
        self.assertIn('github_code_scanning_alerts_open{severity="error"} 1', out)
        self.assertIn('github_code_scanning_alerts_open{severity="critical"} 0', out)

    def test_no_alerts_still_reports_the_poll(self):
        out = ga.render([], 1234.5)
        self.assertNotIn("github_code_scanning_alert{", out)
        self.assertIn("github_code_scanning_poll_success_timestamp_seconds 1234", out)

    def test_labels_are_escaped(self):
        out = ga.render([alert(1, desc='a "b" \\ c\nd')], 0)
        self.assertIn(r'summary="a \"b\" \\ c d"', out)


class Fetch(unittest.TestCase):
    def test_follows_pages(self):
        pages = {
            "first": ([alert(1)], '<https://api.github.com/next>; rel="next", <x>; rel="last"'),
            "https://api.github.com/next": ([alert(2)], ""),
        }
        calls = []

        def fetch(url):
            calls.append(url)
            return pages["first"] if len(calls) == 1 else pages[url]

        self.assertEqual([a["number"] for a in ga.open_alerts(fetch)], [1, 2])
        self.assertEqual(len(calls), 2)


class Write(unittest.TestCase):
    def test_replaces_the_file_whole(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "g.prom")
            ga.write("one\n", p)
            ga.write("two\n", p)
            self.assertEqual(Path(p).read_text(), "two\n")
            self.assertEqual(os.listdir(d), ["g.prom"])


if __name__ == "__main__":
    unittest.main()
