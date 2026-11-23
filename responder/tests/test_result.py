"""Tests for reading Claude's JSON result. Run: python3 -m unittest discover -s responder/tests"""
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import unittest

for k, v in (("RESPONDER_BIND", "127.0.0.1"), ("RESPONDER_TOKEN", "test"),
             ("RESPONDER_HA_URL", "https://example.invalid/")):
    os.environ.setdefault(k, v)
SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "root/usr/local/bin/responder"
loader = importlib.machinery.SourceFileLoader("responder", str(SCRIPT))
spec = importlib.util.spec_from_loader("responder", loader)
responder = importlib.util.module_from_spec(spec)
loader.exec_module(responder)

DENIAL = {"tool_name": "Bash", "tool_use_id": "toolu_x",
          "tool_input": {"command": "ls   /tmp\n| head", "description": "List /tmp"}}


def out(**d):
    return json.dumps({"type": "result", "subtype": "success", "is_error": False, **d})


class Result(unittest.TestCase):
    def test_report_without_refusals(self):
        got = responder.parse_result(0, out(result=" text\nVERDICT: unsure\n",
                                            permission_denials=[]), "")
        self.assertEqual(got, ("text\nVERDICT: unsure", []))

    def test_refusals_are_named(self):
        _, denied = responder.parse_result(0, out(result="r", permission_denials=[DENIAL]), "")
        self.assertEqual(denied, ["Bash: ls /tmp | head"])

    def test_read_refusal_names_the_file(self):
        d = {"tool_name": "Read", "tool_input": {"file_path": "/etc/responder/responder.env"}}
        _, denied = responder.parse_result(0, out(result="r", permission_denials=[d]), "")
        self.assertEqual(denied, ["Read: /etc/responder/responder.env"])

    def test_failed_run_raises_with_its_refusals(self):
        """As Claude Code prints it when a run hits its budget: no `result` key."""
        bad = json.dumps({"type": "result", "subtype": "error_max_budget_usd",
                          "is_error": True, "permission_denials": [DENIAL]})
        with self.assertRaisesRegex(RuntimeError, r"error_max_budget_usd.*refused Bash: ls"):
            responder.parse_result(1, bad, "")

    def test_output_that_is_not_json(self):
        with self.assertRaisesRegex(RuntimeError, "exited 1: not logged in"):
            responder.parse_result(1, "", "not logged in\n")


if __name__ == "__main__":
    unittest.main()
