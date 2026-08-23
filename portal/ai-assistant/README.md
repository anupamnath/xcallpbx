# XCall — AI Assistants

Manage voice AI assistants from the portal: write the **context** the assistant
follows, pick the **model provider** (API key **or your local machine**), and
the agent runs it on inbound calls — then hands off to a human specialist when
needed. This is a Telnyx-style assistant manager built into the XCall portal.

## Install

1. Create the tables (PostgreSQL):

   ```bash
   psql -U fusionpbx -d fusionpbx -f portal/ai-assistant/schema.sql
   ```

2. Copy the app into the FusionPBX web root (it sits next to `webphone/`):

   ```bash
   cp -r portal/ai-assistant /var/www/fusionpbx/ai-assistant
   chown -R www-data:www-data /var/www/fusionpbx/ai-assistant
   ```

3. Open the portal → the "AI Assistants" entry under AI Suite (or browse to
   `https://<host>/ai-assistant/assistants.php`).

## Usage

1. **Create an assistant** — give it a name, greeting, and instructions
   (the "context": your business, policies, tone, escalation rules).
2. **Pick a model**:
   - **API key**: OpenAI, Anthropic Claude, Google Gemini, Groq, or any
     OpenAI-compatible endpoint (paste your key — it is encrypted at rest).
   - **Local machine**: choose *Ollama*, set the base URL to your Ollama
     server (`http://192.168.1.50:11434`) and a model (`llama3.1`). No key.
3. **Save**. The assistant is now active for calls routed to the AI agent.
4. The agent runs: greeting → listen → LLM reply → listen → … until the LLM
   decides to **transfer to a specialist** or **hang up** (via tool calls).

## How the AI agent picks up the assistant

The agent fetches the active assistant config over HTTPS from:

```
assistant_api.php?action=agent_config&key=<shared_secret>
```

The shared secret is stored in `v_xcall_settings.agent_shared_secret`
(created by `schema.sql`) — the agent's `config.yaml` must set the same value:

```yaml
agent:
  mode: "assistant"
assistant:
  portal_url: "https://portal.example.com/ai-assistant/assistant_api.php"
  portal_secret: "<secret from v_xcall_settings>"
```

For testing without the portal, point `assistant.assistant_file` at a local
JSON file (see `ai-agent/assistant.example.json`).

## API keys

Keys are encrypted with **AES-256-GCM** before storage. The encryption key is
auto-generated on first use into `resources/xcall_secrets.php` (chmod 600) —
back it up; if it is lost, saved keys can no longer be decrypted (re-enter
them). Keys are never returned to the browser UI and never logged.

## Security notes

- The `agent_config` endpoint is authenticated with a shared secret and is
  meant for the agent process (server-side) — keep it secret.
- Keep `xcall_secrets.php` outside the web-accessible path if possible, or
  ensure the server blocks `.php` access appropriately (it is in
  `resources/`, which PHP can execute but is not directly browsable).
- Enable HTTPS on the portal; otherwise API keys transit in cleartext.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Database not initialised" | Run `schema.sql` (step 1 above). |
| Agent says "no assistant config source" | Set `agent.mode: assistant` + `portal_url` + `portal_secret` in `ai-agent/config.yaml`. |
| 401 from agent_config | `portal_secret` in config.yaml does not match `v_xcall_settings.agent_shared_secret`. |
| LLM 401/403 | Wrong API key in the assistant settings. |
| Local Ollama unreachable | Confirm Ollama listens on `0.0.0.0:11434` (not just localhost) and the base URL is reachable from the PBX. |
| Assistant talks but never transfers | Add transfer instructions to the context, e.g. "if you cannot resolve it, call transfer_to_specialist". |
