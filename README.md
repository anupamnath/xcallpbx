# XCall — Self-Hosted PBX on FreeSWITCH + FusionPBX

**XCall** is a complete, self-hosted phone system built on top of **FreeSWITCH** (media/telephony
engine) and **FusionPBX** (management portal, rebranded here as "XCall"). It provides:

- **WebRTC provisioning** — agents and users register with the system using their browser
  (an embedded SIP.js softphone in the portal). No desktop client required.
- **Web login portal** — the XCall portal (rebranded FusionPBX) with a custom theme, logo, and
  an in-browser softphone for making/receiving calls, transferring, and answering queues.
- **AI voice agent** — an inbound voice bot (Python) that answers calls. Two
  engines:
  - *Assistant mode* (new): an LLM runs the whole conversation using the
    assistant you configure in the portal — write your own context, pick any
    provider (OpenAI/Anthropic/Gemini/Groq via API key, or your local machine
    via Ollama) — and the bot transfers callers to a human specialist when the
    LLM decides to escalate.
  - *Script mode*: a YAML state machine (TTS → record → STT → next step) that
    plays a fixed flow and forwards to a human specialist.
- **AI Assistant manager** — a Telnyx-style portal page (`/ai-assistant/`)
  where you add context, choose the model (API key or local machine), set the
  voice/handoff settings, and the agent picks it up on the next call.
  Local models are auto-detected — **Ollama, LM Studio, vLLM, llama.cpp,
  LocalAI** — with a one-click **"⚡ Detect local AI models"** button.
- **Admin panel** — an extra portal section (`/admin/`) where you can:
  - **name your system** (brand text + colors pushed across the portal),
  - enter **company details** (name, phone, email, address, website, logo),
  - **maintain client data** (a lightweight CRM: contacts, companies, status),
  - **customize the softphone** (theme, ringtone, hold music, auto-answer).
- **Local AI integration** — STT, LLM, and TTS all run against local engines
  (faster-whisper / whisper.cpp, Ollama, Piper), so no call audio leaves your
  network unless you choose a cloud provider for the assistant's LLM.

> **Purpose.** XCall is a legitimate self-hosted PBX. It is designed for real businesses —
> e.g. an IT helpdesk where a bot performs first-line triage and hands difficult cases to a
> human technician. The included sample script (`ai-agent/scripts/helpdesk_triage.yaml`) is a
> clean, honest support-flow that demonstrates the full architecture. Use it only for lawful
> purposes and with the consent of everyone on the call.

---

## Repository layout

```
ai-agent/          Python AI voice agent (ESL client, script + assistant engines, LLM chat, tests)
freeswitch/        FreeSWITCH configuration (dialplan, verto/WebRTC, sofia, ESL, ACLs)
portal/            XCall branding + admin panel + web softphone + AI Assistant manager
docker/            Docker Compose + images (FreeSWITCH, portal, AI agent)
deploy/            Self-contained VPS installer (bootstrap.sh + provision.sh, Debian 12)
docs/              Architecture, setup, WebRTC provisioning, AI agent guide, VPS deploy/hosting
```

## Quick start (Docker)

```bash
cp docker/.env.example docker/.env      # edit passwords / domain
cd docker && docker compose up -d --build
```

Then:

1. Open `https://<server>/` and complete the XCall portal installer (it seeds PostgreSQL,
   creates the admin account, and provisions FreeSWITCH dialplan/softphone settings).
2. Create a specialist extension (e.g. `7000`) with WebRTC enabled.
3. Start the AI agent (inside the compose stack) so it connects to FreeSWITCH over ESL.
4. Dial the AI-agent extension (e.g. `5000`) from the web softphone — the bot answers,
   runs the triage script, then transfers to extension `7000`.

## One-command VPS install (Debian 12)

On any bare Debian 12 VPS, as root or a sudo user:

```bash
curl -fsSL https://raw.githubusercontent.com/anupamnath/xcallpbx/main/deploy/bootstrap.sh | sudo bash
```

With a real domain + TLS + explicit passwords:

```bash
curl -fsSL https://raw.githubusercontent.com/anupamnath/xcallpbx/main/deploy/bootstrap.sh | \
  sudo bash -s -- --domain pbx.example.com --admin-pass 'Str0ngPass1' \
    --db-pass 'PgPass1' --esl-pass 'ClueCon!' --email you@example.com
```

This installs **FreeSWITCH + FusionPBX (rebranded XCall) + the admin panel +
AI Assistant manager + WebRTC softphone + AI voice agent** from a bare box,
then configures nginx (TLS), the firewall, and the systemd services.

> **FreeSWITCH packaging note.** The legacy public apt repo
> (`files.freeswitch.org`) now requires a SignalWire login, so the installer
> uses FusionPBX's official Debian installer and **builds FreeSWITCH 1.10.12
> from source** by default (self-contained, ~30–60 min). To use the fast
> official package repo instead, grab a free
> token from https://signalwire.com and add
> `--signalwire-token '<token>'` to the command above.

Full syntax and first-login steps: **[docs/VPS_DEPLOY.md](docs/VPS_DEPLOY.md)**.

See [docs/SETUP.md](docs/SETUP.md) for the step-by-step guide (Docker and bare-metal),
[docs/WEBRTC_PROVISIONING.md](docs/WEBRTC_PROVISIONING.md) for browser registration details,
and [docs/AI_AGENT.md](docs/AI_AGENT.md) for writing your own conversation scripts.

## Requirements

- Linux server (Ubuntu 22.04+ recommended) or any host with Docker.
- A SIP trunk / phone number for real inbound calls (optional — the system works fully
  on internal extensions without a trunk).
- For the AI agent: a local Whisper installation (or `faster-whisper`), `piper` TTS, and
  `ollama` (all optional — see `ai-agent/config.example.yaml`).

## Quick start (development / tests only, no PBX needed)

The AI agent is fully unit-testable without FreeSWITCH:

```bash
cd ai-agent
python -m venv .venv && .venv/Scripts/activate   # or: source .venv/bin/activate (Linux)
pip install -r requirements.txt
python -m unittest discover -s tests -v
```

This runs the script engine, the ESL client (against a mock FreeSWITCH), and an
end-to-end conversation test that simulates an entire call from greeting to handoff.

---

*XCall is an independent rebrand/configuration of the FusionPBX project, which is licensed
under the Mozilla Public License 1.1. FreeSWITCH is licensed under the Mozilla Public
License 1.1. See the respective projects for details.*
