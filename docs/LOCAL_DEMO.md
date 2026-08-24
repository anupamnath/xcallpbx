# XCall — Local Demo (Windows)

Preview the XCall portal + AI Assistant manager on this machine **without**
Docker, FreeSWITCH, or PostgreSQL. A small PHP dev harness serves the pages
and uses SQLite for storage so you can click through everything.

## Quick start

```bat
local\start-demo.bat
```

Open one of:

| What | URL |
|---|---|
| Portal landing | http://127.0.0.1:8080/ |
| AI Assistants | http://127.0.0.1:8080/ai-assistant/assistants.php |
| Web softphone | http://127.0.0.1:8080/webphone/index.html |
| Assistant API (JSON) | http://127.0.0.1:8080/ai-assistant/assistant_api.php?action=list |

Stop with `local\stop-demo.bat`.

## What's happening under the hood

- `tools\php\` — a portable PHP 8.4 (NTS) runtime downloaded from
  windows.php.net. Gitignored; re-fetch with `local\fetch-php.bat` if missing.
- `local\resources-shim.php` → copied to `resources\require.php` — a
  stand-in for FusionPBX's `require.php`: auto-login as `admin`, a SQLite-backed
  `$database` matching the FusionPBX method signature, and a minimal
  `settings` class. **Demo only, not for production.**
- `portal\resources\require.php` — same shim for the web softphone's config.
- `local\dev-router.php` — PHP built-in-server router (serves the landing page
  at `/`, everything else maps to `portal\`).
- `local\php.ini` — enables the extensions the portal needs (openssl for
  AES-256-GCM key encryption, pdo_sqlite, curl, mbstring).
- `local\xcall_demo.sqlite` — the demo database (created on first request,
  gitignored). Delete it to reset all assistants.

## What you can test here

- Create / edit / duplicate / delete AI assistants (Telnyx-style editor).
- Pick any provider: OpenAI / Anthropic / Gemini / Groq / OpenAI-compatible
  via **API key**, or **local machine** via Ollama (no key).
- The API encrypts keys at rest (AES-256-GCM) and the pages never receive them.
- The Python AI agent (`ai-agent/`) can load the active assistant from the
  portal (`agent_config` + shared secret) — verified by
  `local\agent_live_check.py`.

## What is NOT running here (needs the VPS / Docker)

- FreeSWITCH (SIP / verto / ESL) — the softphone UI renders but cannot place
  calls without it.
- FusionPBX PostgreSQL schema — replaced by the SQLite demo shim.
- Real STT/TTS/LLM — the agent's `assistant` mode talks to real models on the
  server; use `assistant.example.json` or the portal endpoint to test config.

See `docs/SETUP.md` / `docs/VPS_HOSTING.md` for the full production install.
