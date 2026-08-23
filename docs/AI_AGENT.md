# XCall — AI Agent Guide

The AI agent answers inbound calls and either:

- **assistant mode** (recommended) — the **LLM runs the conversation** using the
  assistant you configure in the portal (`/ai-assistant/`): your context,
  model provider (API key or local machine), voice, and handoff settings. The
  LLM decides when to say "please hold" and transfer to a human specialist.
- **script mode** — follows a YAML state machine (the original behaviour).

It never places outbound calls on its own.

## Quick start (stub engines)

```bash
cd ai-agent
python -m venv .venv && source .venv/bin/activate   # Linux
pip install -r requirements.txt
cp config.example.yaml config.yaml

# dry-run validation (no FreeSWITCH needed)
python -m xcall_agent --config config.yaml --dry-run

# unit tests (mock ESL, no FreeSWITCH needed)
python -m unittest discover -s tests -v

# run for real (FreeSWITCH ESL on 8021)
python -m xcall_agent --config config.yaml
```

With default config the STT/TTS/LLM engines are **stubs** — the bot speaks
canned audio and "hears" a canned transcript. That's enough to prove the flow
end-to-end. Enable real local AI below.

## The conversation script

`ai-agent/scripts/helpdesk_triage.yaml` is a YAML state machine:

```yaml
meta:
  company: "Acme Corp"
start: greeting
nodes:
  greeting:
    prompt: "Thank you for calling ... what is the issue?"
    collect: issue
  confirm_issue:
    prompt: "You said {issue}. Correct?"
    branches:
      yes:  { keywords: [yes, yeah, correct, right], next: triage }
      _fallback: { next: confirm_issue }        # re-ask on no match
  ...
  hold_and_transfer:
    prompt: "Please hold while I check with a specialist."
    wait: false
    action:
      type: handoff
      destination: "7000"                       # rings the human specialist
      message: "Please hold, connecting you to a senior specialist."
```

Node fields:

| Field | Meaning |
|---|---|
| `prompt` | Text spoken by the bot (`{var}` templated from `meta` + collected values). |
| `collect` | Store the caller's answer in context under this key. |
| `branches` | Intent → `{keywords: [...], next: node}`; `_fallback` is the no-match default. |
| `next` | Explicit next node (overrides file order). |
| `wait: false` | Don't pause for input (e.g. just before handoff). |
| `action` | `{type: handoff}` transfers to a human; `{type: hangup}` ends the call. |

### Writing your own scripts
- Keep `start` present and valid; every referenced node must exist.
- Use `_fallback` on question nodes to re-ask instead of derailing.
- Collect sensitive info only where your policy allows; prefer transferring
  early rather than gathering more than needed.
- Reuse the same structure for any legitimate flow: after-hours support,
  order lookup, appointment booking, outage triage.

## Local AI engines

All engines run locally (no cloud). Set them in `config.yaml`.

### STT — whisper (faster-whisper)
```bash
pip install faster-whisper
```
```yaml
stt:
  engine: whisper
  model: base            # tiny|base|small|medium (CPU: base is a good balance)
  device: cpu
  compute_type: int8
```
Alternative: `engine: vosk` with `model_path` set to a vosk model directory.

### TTS — piper (natural, fast)
Install `piper` (e.g. `pip install piper-tts` or the release binary) and
download a voice:
```bash
# https://github.com/rhasspy/piper/releases
# voice: en_US-lessac-medium
mkdir -p ai-agent/models
wget -P ai-agent/models \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx
```
```yaml
tts:
  engine: piper
  piper_path: piper
  piper_model: models/en_US-lessac-medium.onnx
  cache_dir: tts_cache
```
Fallback: `engine: espeak` (robotic but always available via `espeak-ng`).

### LLM — ollama (response classification)
```bash
# install ollama, then pull a model
ollama pull llama3.1
```
```yaml
llm:
  engine: ollama
  base_url: http://127.0.0.1:11434
  model: llama3.1
```
If the LLM is unreachable, the agent falls back to keyword matching
(`fallback_to_keywords: true`).


## Assistant mode (LLM-driven conversations)

This is the recommended mode: you configure everything from the portal's
**AI Assistants** page (`/ai-assistant/assistants.php`) and the agent uses it
on calls.

### Configure the agent for assistant mode

```yaml
agent:
  mode: "assistant"          # instead of "script"

assistant:
  # production: fetch from the portal (secret = v_xcall_settings.agent_shared_secret)
  portal_url: "https://portal.example.com/ai-assistant/assistant_api.php"
  portal_secret: "<secret>"
  # OR offline/test: a local JSON file (see assistant.example.json)
  # assistant_file: "assistant.example.json"
```

Run it:

```bash
python -m xcall_agent --config config.yaml          # assistant mode
python -m xcall_agent --config config.yaml --dry-run
```

### How a call plays out

1. Caller rings the AI extension → FreeSWITCH parks the leg.
2. The agent plays the assistant's **greeting**.
3. Loop: record the caller → STT → send to the LLM (with your **instructions/
   context** as the system prompt) → speak the reply → repeat.
4. The LLM can call three tools:
   - `transfer_to_specialist` — plays the hold message, then
     `uuid_transfer <uuid> <ext> xml default` to the specialist.
   - `hang_up` — ends the call politely.
   - `skip_turn` — stays silent (e.g. caller said "one moment").

The context you write in the portal is what makes the assistant behave
correctly — e.g. "…if you cannot resolve the issue, call
transfer_to_specialist", "…be concise", "…never ask for a card number".

### Providers

Any of: OpenAI, Anthropic, Gemini, Groq, an OpenAI-compatible endpoint, or
**local Ollama** (base URL to your machine, no API key). API keys are
encrypted at rest in the portal DB (AES-256-GCM) and delivered to the agent
over the authenticated `agent_config` endpoint.


## Integration with FreeSWITCH

- The agent connects to **ESL** (`event_socket.conf.xml`, port 8021). Keep the
  password in sync with `config.yaml`.
- FreeSWITCH parks inbound calls into the `xcall_ai` context with
  `xcall_agent=true`. The agent watches `CHANNEL_PARK` for that context/var.
- On handoff the agent runs `uuid_transfer <uuid> <dest> xml default`. Create
  the destination extension in the portal (WebRTC enabled) and keep its
  softphone open.
- Recordings land in `/var/spool/xcall/recordings/<uuid>/` (writable by the
  freeswitch/systemd user).

## Monitoring / debugging

```bash
# live transcript + state transitions
journalctl -u xcall-agent -f        # bare metal
docker compose logs -f ai-agent     # docker

# a slow call? bump timing values
#   timing.max_call_seconds, no_speech_retries, max_utterance_seconds
```

## Behavior notes
- If the caller says nothing, the agent re-prompts up to `no_speech_retries`
  times, then routes to the specialist (never loops forever).
- If the call exceeds `max_call_seconds`, the agent apologizes and ends the
  call gracefully.
- A caller hangup mid-script cleans up the session and issues no transfer.
