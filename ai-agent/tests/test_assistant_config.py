import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from xcall_agent.assistant_config import (  # noqa: E402
    AssistantConfigError,
    build_greeting,
    build_system_prompt,
    load_assistant_config,
)

SAMPLE = {
    "assistant": {
        "assistant_name": "Bob",
        "assistant_greeting": "Hello from {company_name}.",
        "assistant_instructions": "You are Bob at {company_name}. Be brief.",
        "assistant_provider": "openai",
        "assistant_model": "gpt-4o-mini",
        "assistant_handoff_extension": "7000",
    }
}


class TestAssistantConfig(unittest.TestCase):
    def test_load_local_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as fh:
            json.dump(SAMPLE, fh)
            path = fh.name
        try:
            cfg = load_assistant_config({"assistant_file": path})
            self.assertEqual(cfg["assistant_name"], "Bob")
            self.assertEqual(cfg["assistant_model"], "gpt-4o-mini")
        finally:
            os.unlink(path)

    def test_missing_source_raises(self):
        with self.assertRaises(AssistantConfigError):
            load_assistant_config({"assistant_file": "", "portal_url": ""})

    def test_build_system_prompt_templates(self):
        cfg = SAMPLE["assistant"]
        prompt = build_system_prompt(cfg, {"company_name": "Acme"})
        self.assertIn("Acme", prompt)
        self.assertIn("Be brief", prompt)

    def test_build_greeting_templates(self):
        cfg = SAMPLE["assistant"]
        greeting = build_greeting(cfg, {"company_name": "Acme"})
        self.assertEqual(greeting, "Hello from Acme.")


if __name__ == "__main__":
    unittest.main()
