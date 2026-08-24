"""Prove the Python AI agent can load its assistant from the LIVE local portal."""
import sys

sys.path.insert(0, "ai-agent")

from xcall_agent.assistant_config import load_assistant_config  # noqa: E402

cfg = {
    "assistant_file": "",
    "portal_url": "http://127.0.0.1:8080/ai-assistant/assistant_api.php",
    "portal_secret": None,  # filled below from the demo DB
}

import sqlite3
con = sqlite3.connect("local/xcall_demo.sqlite")
cfg["portal_secret"] = con.execute(
    "select setting_value from v_xcall_settings where setting_name='agent_shared_secret'"
).fetchone()[0]
con.close()

a = load_assistant_config(cfg)
print("agent loaded assistant:", a.get("assistant_name"))
print("provider :", a.get("assistant_provider"))
print("model    :", a.get("assistant_model"))
print("greeting :", a.get("assistant_greeting")[:60])
print("handoff  :", a.get("assistant_handoff_extension"))
assert a.get("assistant_name")
print("PASS: AI agent <- portal integration works")
