"""XCall local demo live verification (runs against http://127.0.0.1:8080)."""
import json
import urllib.request
import urllib.error

BASE = "http://127.0.0.1:8080"
FAILS = []


def get(path, expect_status=200):
    try:
        r = urllib.request.urlopen(BASE + path, timeout=10)
        body = r.read().decode("utf-8", "replace")
        status = r.status
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        status = e.code
    ok = status == expect_status
    return ok, status, body


def check(name, ok, detail=""):
    mark = "OK " if ok else "FAIL"
    print(f"[{mark}] {name}" + (f"  -> {detail[:200]}" if (detail and not ok) else ""))
    if not ok:
        FAILS.append(name)
    return ok


ok, status, body = get("/")
check("landing page /", ok and "XCall Portal" in body, f"{status} {body[:120]}")

ok, status, body = get("/ai-assistant/assistants.php")
check("assistants list page", ok and "AI Assistants" in body, f"{status} {body[:200]}")

ok, status, body = get("/ai-assistant/assistant_edit.php")
check("assistant editor page", ok and "assistant_instructions" in body, f"{status} {body[:200]}")

ok, status, body = get("/webphone/index.html")
check("web softphone page", ok and ("softphone" in body.lower() or "sip" in body.lower()), f"{status} {body[:120]}")

ok, status, body = get("/webphone/config.php")
try:
    cfg = json.loads(body)
    good = ok and cfg.get("username") == "admin" and "extension" in cfg
except Exception:
    good = False
    cfg = {}
check("webphone config.php JSON", good, f"{status} {body[:200]}")

ok, status, body = get("/ai-assistant/assistant_api.php?action=list")
try:
    data = json.loads(body)
    good = ok and "assistants" in data
except Exception:
    good = False
    data = {}
check("assistant_api action=list", good, f"{status} {body[:200]}")

# ---- save a new assistant ----
payload = json.dumps({
    "assistant_name": "Demo Support Bot",
    "assistant_greeting": "Hello, this is the XCall demo assistant.",
    "assistant_instructions": "You are a helpful support bot. If you cannot resolve, transfer to extension 7000.",
    "assistant_provider": "openai",
    "assistant_model": "gpt-4o-mini",
    "assistant_api_key": "sk-demo-key-1234",
    "assistant_api_base_url": "https://api.openai.com/v1",
    "assistant_temperature": 0.7,
    "assistant_max_tokens": 1024,
    "assistant_enabled": True,
    "assistant_handoff_extension": "7000",
}).encode()
req = urllib.request.Request(
    BASE + "/ai-assistant/assistant_api.php?action=save",
    data=payload, headers={"Content-Type": "application/json"}, method="POST",
)
try:
    r = urllib.request.urlopen(req, timeout=10)
    sbody = r.read().decode()
    saved = json.loads(sbody).get("saved") is True
except Exception as e:
    saved = False
    sbody = str(e)
check("assistant_api action=save", saved, sbody[:200])

ok, status, body = get("/ai-assistant/assistant_api.php?action=list")
try:
    data = json.loads(body)
    items = data.get("assistants", [])
    good = ok and any(a["assistant_name"] == "Demo Support Bot" for a in items)
except Exception:
    good = False
    items = []
check("list shows saved assistant", good, f"{status} {body[:200]}")

uuid = next((a["assistant_uuid"] for a in items if a["assistant_name"] == "Demo Support Bot"), "")
ok, status, body = get(f"/ai-assistant/assistant_api.php?action=get&assistant_uuid={uuid}")
try:
    a = json.loads(body).get("assistant", {})
    good = ok and "sk-demo-key-1234" in body
except Exception:
    good = False
check("get returns decrypted key", good, f"{status} {body[:200]}")

# ---- agent_config with wrong + right secret ----
ok, status, body = get("/ai-assistant/assistant_api.php?action=agent_config&key=wrong")
check("agent_config rejects bad key (401)", status == 401, f"{status} {body[:120]}")

ok, status, body = get("/ai-assistant/assistant_api.php?action=default_config")
try:
    a = json.loads(body).get("assistant", {})
    good = ok and "assistant_name" in a
except Exception:
    good = False
check("default_config works", good, f"{status} {body[:200]}")

# ---- delete ----
req = urllib.request.Request(
    BASE + f"/ai-assistant/assistant_api.php?action=delete&assistant_uuid={uuid}",
    data=b"{}", method="POST",
)
try:
    r = urllib.request.urlopen(req, timeout=10)
    dbody = r.read().decode()
    deleted = json.loads(dbody).get("deleted") is True
except Exception as e:
    deleted = False
    dbody = str(e)
check("assistant_api action=delete", deleted, dbody[:120])

print("\n==== RESULT:", "ALL PASSED" if not FAILS else f"{len(FAILS)} FAILED: {FAILS}", "====")
