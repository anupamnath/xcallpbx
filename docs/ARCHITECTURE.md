# XCall — Architecture

XCall is a self-hosted PBX built on **FreeSWITCH** (media engine) and
**FusionPBX** (management portal, rebranded to XCall), with a Python **AI voice
agent** for inbound call automation. Clients use a **web softphone** embedded in
the portal — there is no desktop app.

```
                    ┌──────────────────────────────────────────────┐
                    │                XCall Portal                   │
                    │   (rebranded FusionPBX + web softphone)       │
                    │                                              │
                    │   Login → Dashboard → /webphone/ (SIP.js)    │
                    └──────┬──────────────────────────┬────────────┘
                           │ HTTPS / WSS              │
                           ▼                          ▼
              ┌────────────────────┐      ┌─────────────────────┐
              │    FreeSWITCH      │      │     AI Agent        │
              │                    │      │     (Python)        │
              │  mod_sofia   (SIP) │      │                     │
              │  mod_verto  (WSS)  │◄────►│  ESL client (8021)  │
              │  mod_event_socket  │      │  script engine      │
              │  dialplan          │      │  STT / LLM / TTS    │
              └───────┬────────────┘      └─────────────────────┘
                      │
                      ▼
              PSTN / SIP trunk / LAN phones
```

## Components

### 1. FreeSWITCH (`freeswitch/`)
- **`mod_sofia`** — SIP endpoints (internal profile, WebRTC-friendly with
  ICE/DTLS-SRTP) **and** the SIP-over-WebSocket listener (RFC 7118) the
  in-browser softphone registers on (8081 ws / 8082 wss, via nginx `/verto`).
- **`mod_verto`** — optional verto.js JSON-protocol endpoint (8083 ws / 8084
  wss) for FusionPBX's classic communicator; the XCall softphone uses SIP.js
  over mod_sofia instead.
- **`mod_event_socket`** — ESL (8021) that the AI agent drives.
- **Dialplan**:
  - `xcall_ai` context — inbound calls destined for the bot are answered,
    marked (`xcall_agent=true`), and **parked**.
  - `default` context — the specialist extension (7000), internal routing,
    echo/timing test extensions.

### 2. XCall Portal (`portal/`)
- Stock FusionPBX with the **XCall brand** applied:
  - `xcall.css` injected via the theme `custom_css` setting.
  - `logo.svg` / `favicon.svg` in the default theme images.
  - Branding SQL (`xcall_rebrand.sql`) sets name, footer, palette in
    `v_default_settings`.
- **Web softphone** (`webphone/`): SIP.js (vendored, offline) registers the
  logged-in portal user to FreeSWITCH over WSS. `config.php` returns the
  user's SIP credentials from the portal session, so no password is typed in
  the browser.

### 3. AI Agent (`ai-agent/`)
A Python service that connects to FreeSWITCH via ESL and runs a **scripted
conversation**:

```
CHANNEL_PARK (in xcall_ai context)
      │
      ▼
answer + loop over script nodes
      │
      ├─ speak node.prompt      (TTS → wav → uuid_broadcast playback)
      ├─ record caller answer   (uuid_record → wav)
      ├─ trim silence + STT     (whisper / vosk / stub)
      ├─ route by keywords/LLM  (classify → next node)
      ▼
handoff node → "please hold" → uuid_transfer <ext> → human specialist rings
```

Key modules:
- `esl_client.py` — minimal Event Socket client (auth, api, events).
- `script_engine.py` — YAML state machine (`Script` / `ScriptNode`).
- `orchestrator.py` — `VoiceAgent` drives parked calls; handles silence,
  timeouts, hangup cleanup, and the handoff transfer.
- `stt.py` / `tts.py` / `llm.py` — pluggable local engines (stub by default;
  whisper/vosk, piper/espeak, ollama optionally).
- `audio.py` — wav I/O + energy VAD / silence trimming.

## Call flows

### Inbound → AI bot → human specialist
1. Caller dials the number/extension routed to the `xcall_ai` context.
2. FreeSWITCH answers and parks the leg with `xcall_agent=true`.
3. The agent sees `CHANNEL_PARK`, runs the script (greeting → triage →
   verify), then plays the hold message and issues `uuid_transfer <uuid>
   7000 xml default`.
4. Extension 7000 rings the specialist's web softphone; the specialist picks
   up and the caller and specialist are bridged.

### Agent-to-agent / internal
Agents dial extensions from the web softphone; the `default` context bridges
`user/<ext>@<domain>`.

## Security model
- ESL password in `event_socket.conf.xml` must match the agent's config.
- ACLs (`acl.conf.xml`) restrict ESL/agent traffic to trusted subnets.
- WebRTC requires TLS; nginx terminates HTTPS and proxies verto WSS.
- The web softphone gets credentials from the portal session — never from
  client-side storage.

## Performance notes
- Portal CSS/JS are cached (`Cache-Control`), gzip on the proxy, HTTP/2.
- The agent pre-caches TTS output (`tts_cache/`) so repeat prompts play
  instantly.
- STT/VAD run locally; no call audio leaves the server (unless you point STT
  at a remote endpoint).
