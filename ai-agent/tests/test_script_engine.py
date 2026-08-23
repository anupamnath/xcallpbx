import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tests"))

from xcall_agent.script_engine import Script, ScriptNode, ScriptError  # noqa: E402

SCRIPT_YAML = """
meta:
  company: Acme
start: greeting
nodes:
  greeting:
    prompt: Hello from {company}.
    collect: issue
    next: confirm
  confirm:
    prompt: You said {issue}. Correct?
    branches:
      yes:
        keywords: [yes, correct]
        next: handoff
      _fallback:
        next: confirm
  handoff:
    prompt: Holding.
    action:
      type: handoff
      destination: "7000"
"""


class TestScriptEngine(unittest.TestCase):
    def setUp(self):
        self.script = Script()
        self.script.meta = {"company": "Acme"}
        self.script.start = "greeting"
        self.script.nodes = {
            "greeting": ScriptNode(id="greeting", prompt="Hello from {company}.", collect="issue", next="confirm"),
            "confirm": ScriptNode(
                id="confirm",
                prompt="You said {issue}. Correct?",
                branches={"yes": {"keywords": ["yes", "correct"], "next": "handoff"}, "_fallback": {"next": "confirm"}},
            ),
            "handoff": ScriptNode(id="handoff", prompt="Holding.", action={"type": "handoff", "destination": "7000"}),
        }
        self.script.order = ["greeting", "confirm", "handoff"]

    def test_template(self):
        text = self.script.template("Hello from {company}.", {"company": "Acme"})
        self.assertEqual(text, "Hello from Acme.")

    def test_keyword_branch(self):
        node = self.script.nodes["confirm"]
        self.assertEqual(node.matches("yes that is right"), "handoff")
        self.assertIsNone(node.matches("nope"))

    def test_next_id_uses_branch(self):
        node = self.script.nodes["confirm"]
        ctx = {"last_utterance": "yes correct"}
        self.assertEqual(self.script.next_id(node, ctx), "handoff")

    def test_next_id_fallback(self):
        node = self.script.nodes["confirm"]
        ctx = {"last_utterance": "maybe not"}
        self.assertEqual(self.script.next_id(node, ctx), "confirm")

    def test_next_id_explicit(self):
        node = self.script.nodes["greeting"]
        self.assertEqual(self.script.next_id(node, {}), "confirm")

    def test_load_from_yaml(self):
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, encoding="utf-8") as fh:
            fh.write(SCRIPT_YAML)
            path = fh.name
        try:
            script = Script.load(path)
            self.assertEqual(script.start, "greeting")
            self.assertEqual(len(script.nodes), 3)
            self.assertEqual(script.meta["company"], "Acme")
        finally:
            os.unlink(path)

    def test_load_missing_start(self):
        import tempfile

        bad = "meta:\n  x: 1\nstart: missing\nnodes:\n  a:\n    prompt: hi\n"
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, encoding="utf-8") as fh:
            fh.write(bad)
            path = fh.name
        try:
            with self.assertRaises(ScriptError):
                Script.load(path)
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
