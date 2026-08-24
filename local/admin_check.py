"""XCall admin panel + AI assistant local-model live verification."""
import json
import sqlite3
import urllib.request

BASE = "http://127.0.0.1:8080"
FAILS = []


def get(path, expect=200):
    try:
        r = urllib.request.urlopen(BASE + path, timeout=10)
        return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def post(path, payload=None):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload or {}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        r = urllib.request.urlopen(req, timeout=10)
        return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def check(name, ok, detail=""):
    mark = "OK " if ok else "FAIL"
    print(f"[{mark}] {name}" + (f"  -> {detail[:180]}" if (detail and not ok) else ""))
    if not ok:
        FAILS.append(name)


# --- admin pages render ---
for path, needle in [
    ("/admin/index.php", "Admin Panel"),
    ("/admin/system.php", "System &amp; Company"),
    ("/admin/clients.php", "Clients"),
    ("/admin/softphone.php", "Softphone"),
]:
    st, body = get(path)
    check(f"page {path}", st == 200 and needle in body, f"{st} {body[:150]}")

# --- company get/save ---
st, body = get("/admin/admin_api.php?action=company_get")
try:
    c = json.loads(body).get("company", {})
    good = st == 200 and "system_name" in c
except Exception:
    good = False
    c = {}
check("company_get", good, f"{st} {body[:150]}")

st, body = post("/admin/admin_api.php?action=company_save", {
    "system_name": "Acme Telco",
    "tagline": "Business voice, done right",
    "company_name": "Acme Telco Ltd",
    "company_phone": "+15551234567",
    "company_email": "hello@acme.test",
})
check("company_save", st == 200 and json.loads(body).get("saved") is True, f"{st} {body[:150]}")

# verify system_name persisted + branding push worked
st, body = get("/admin/admin_api.php?action=company_get")
try:
    c = json.loads(body).get("company", {})
    good = c.get("system_name") == "Acme Telco"
except Exception:
    good = False
check("company_save persisted", good, f"{st} {body[:150]}")

con = sqlite3.connect("local/xcall_demo.sqlite")
brand = con.execute(
    "select default_setting_value from v_default_settings "
    "where default_setting_subcategory='menu_brand_text'"
).fetchone()
con.close()
check("branding push -> v_default_settings", brand and brand[0] == "Acme Telco", str(brand))

# --- clients CRUD ---
st, body = post("/admin/admin_api.php?action=client_save", {
    "client_name": "Jane Doe",
    "client_phone": "+15559876543",
    "client_email": "jane@example.com",
    "client_company": "Acme Telco Ltd",
    "client_notes": "Prefers afternoon calls",
    "client_status": "active",
})
check("client_save", st == 200 and json.loads(body).get("saved") is True, f"{st} {body[:150]}")

st, body = get("/admin/admin_api.php?action=clients_list")
try:
    data = json.loads(body)
    items = data.get("clients", [])
    good = st == 200 and any(x["client_name"] == "Jane Doe" for x in items)
except Exception:
    good = False
    items = []
check("clients_list", good, f"{st} {body[:150]}")

uuid = next((x["client_uuid"] for x in items if x["client_name"] == "Jane Doe"), "")
st, body = post("/admin/admin_api.php?action=client_save", {
    "client_uuid": uuid,
    "client_name": "Jane Doe Updated",
    "client_phone": "+15559876543",
    "client_status": "lead",
})
check("client_update", st == 200 and json.loads(body).get("saved") is True, f"{st} {body[:150]}")

st, body = get("/admin/admin_api.php?action=clients_list")
try:
    data = json.loads(body)
    good = st == 200 and any(x["client_name"] == "Jane Doe Updated" for x in data.get("clients", []))
except Exception:
    good = False
check("client_update persisted", good, f"{st} {body[:150]}")

st, body = post(f"/admin/admin_api.php?action=client_delete&client_uuid={uuid}")
check("client_delete", st == 200 and json.loads(body).get("deleted") is True, f"{st} {body[:150]}")

# --- softphone save ---
st, body = post("/admin/admin_api.php?action=softphone_save", {
    "softphone_theme": "light",
    "softphone_ringtone": "classic",
    "softphone_hold_music": "local_stream://moh",
    "softphone_auto_answer": "true",
    "softphone_enabled": "true",
    "assistant_default_uuid": "",
})
check("softphone_save", st == 200 and json.loads(body).get("saved") is True, f"{st} {body[:150]}")

st, body = get("/admin/admin_api.php?action=company_get")
try:
    c = json.loads(body).get("company", {})
    good = c.get("softphone_theme") == "light" and c.get("softphone_ringtone") == "classic"
except Exception:
    good = False
check("softphone_save persisted", good, f"{st} {body[:150]}")

# --- brand_preview ---
st, body = get("/admin/admin_api.php?action=brand_preview")
try:
    b = json.loads(body).get("brand", {})
    good = st == 200 and b.get("system_name") == "Acme Telco"
except Exception:
    good = False
check("brand_preview", good, f"{st} {body[:150]}")

# --- AI assistant local_models probe (returns 200 even with nothing running) ---
st, body = get("/ai-assistant/assistant_api.php?action=local_models")
try:
    data = json.loads(body)
    good = st == 200 and "servers" in data and isinstance(data["servers"], list)
except Exception:
    good = False
check("local_models probe (no local AI running)", good, f"{st} {body[:150]}")

# --- assistant save with a local provider ---
st, body = post("/ai-assistant/assistant_api.php?action=save", {
    "assistant_name": "Local LLM Bot",
    "assistant_provider": "lmstudio",
    "assistant_model": "local-model",
    "assistant_api_base_url": "http://127.0.0.1:1234/v1",
    "assistant_enabled": True,
})
check("assistant save with lmstudio provider", st == 200 and json.loads(body).get("saved") is True, f"{st} {body[:150]}")

print("\n==== RESULT:", "ALL PASSED" if not FAILS else f"{len(FAILS)} FAILED: {FAILS}", "====")
