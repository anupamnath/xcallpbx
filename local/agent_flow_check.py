"""Verify the AI agent flow against the local demo portal."""
import json
import sqlite3
import urllib.request

BASE = "http://127.0.0.1:8080"

# read the shared secret from the demo DB
con = sqlite3.connect("local/xcall_demo.sqlite")
secret = con.execute(
    "select setting_value from v_xcall_settings where setting_name='agent_shared_secret'"
).fetchone()[0]
con.close()
print("shared secret:", secret[:16], "...")

# save an assistant first so agent_config has something to return
payload = json.dumps({
    "assistant_name": "Frontline Support",
    "assistant_greeting": "Thank you for calling, how can I help?",
    "assistant_instructions": "You are a support agent. If the caller needs a human, transfer to 7000.",
    "assistant_provider": "ollama",
    "assistant_model": "llama3.1",
    "assistant_api_base_url": "http://127.0.0.1:11434",
    "assistant_enabled": True,
}).encode()
req = urllib.request.Request(
    BASE + "/ai-assistant/assistant_api.php?action=save",
    data=payload, headers={"Content-Type": "application/json"}, method="POST",
)
print("save:", urllib.request.urlopen(req, timeout=10).read().decode())

# agent_config with the real secret
url = f"{BASE}/ai-assistant/assistant_api.php?action=agent_config&key={secret}"
body = urllib.request.urlopen(url, timeout=10).read().decode()
data = json.loads(body)
a = data.get("assistant", {})
print("agent_config ok:", a.get("assistant_name"))
print("provider:", a.get("assistant_provider"), "| model:", a.get("assistant_model"))
print("base url:", a.get("assistant_api_base_url"))
