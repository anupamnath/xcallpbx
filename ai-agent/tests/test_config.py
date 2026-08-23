import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from xcall_agent.config import Config  # noqa: E402


class TestConfigEnvOverrides(unittest.TestCase):
    def test_env_overrides(self):
        os.environ["XCALL__ESL__HOST"] = "freeswitch"
        os.environ["XCALL__ESL__PASSWORD"] = "Secret123"
        os.environ["XCALL__AGENT__MODE"] = "assistant"
        os.environ["XCALL__ASSISTANT__PORTAL_URL"] = "https://x.example/ai-assistant/assistant_api.php"
        try:
            cfg = Config.load(None)
            self.assertEqual(cfg.esl["host"], "freeswitch")
            self.assertEqual(cfg.esl["password"], "Secret123")
            self.assertEqual(cfg.agent["mode"], "assistant")
            self.assertEqual(cfg.assistant["portal_url"], "https://x.example/ai-assistant/assistant_api.php")
        finally:
            for k in ("XCALL__ESL__HOST", "XCALL__ESL__PASSWORD", "XCALL__AGENT__MODE", "XCALL__ASSISTANT__PORTAL_URL"):
                os.environ.pop(k, None)


if __name__ == "__main__":
    unittest.main()
