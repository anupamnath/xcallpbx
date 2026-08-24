# XCall — One-Command VPS Deployment (Debian 12)

The whole system installs from a bare Debian 12 VPS with **one command**.
No manual steps.

## The one-liner

```bash
curl -fsSL https://raw.githubusercontent.com/anupamnath/xcallpbx/main/deploy/bootstrap.sh | sudo bash
```

That installs everything: FreeSWITCH, FusionPBX (rebranded **XCall**), the
admin panel (system/company, clients, softphone), the AI assistant manager
(cloud API keys **or local models**), the WebRTC softphone, and the AI voice
agent as a systemd service.

### With options (recommended for a real deployment)

```bash
curl -fsSL https://raw.githubusercontent.com/anupamnath/xcallpbx/main/deploy/bootstrap.sh | \
  sudo bash -s -- \
    --domain pbx.example.com \
    --admin-pass 'SuperStr0ngPass1' \
    --db-pass 'PostgresPass1' \
    --esl-pass 'ChangeMeESL1' \
    --email you@example.com
```

| Option | Meaning |
|---|---|
| `--domain` | Public FQDN of your PBX (default: hostname). Create the DNS A record *before* running with `--email`, so Let's Encrypt can issue a certificate. |
| `--admin-pass` | Portal admin password (default: random, printed at the end). |
| `--db-pass` | PostgreSQL password for the `fusionpbx` role (default: random). |
| `--esl-pass` | FreeSWITCH event-socket password used by the AI agent (default: `ClueCon` — change it). |
| `--email` | If set, the installer runs certbot for a trusted TLS certificate. Without it, a self-signed cert is generated. |
| `--skip-ai` | Skip the AI agent service (the AI assistant page still installs). |
| `--signalwire-token` | Free token from https://signalwire.com → installs FreeSWITCH from the official SignalWire apt repo (fast). Without it, the installer **builds FreeSWITCH 1.10.12 from source** (fully self-contained, no account, ~30–60 min on a 2 vCPU VPS). |

**AI agent default engines:** the agent starts with `STT=stub`, `TTS=espeak`,
`LLM=ollama` (falls back to keyword matching until Ollama is installed) — so
it always runs. To get real speech recognition, install a model and switch
the engine (see `docs/AI_AGENT.md`): `pip install vosk` + a vosk model, or
`pip install faster-whisper`; the portal's **AI Assistants → Voice & Speech**
tab then selects the engine per assistant. For natural TTS, install `piper`.

> **Passwords:** `--admin-pass`, `--db-pass` and `--esl-pass` are restricted
> to **alphanumerics (A-Z a-z 0-9)**. Passwords containing special characters
> would break the config files / SQL, so they are silently stripped to
> alphanumerics (and the final values are printed in the summary).

> **How it works.** The provisioner delegates the base system to **FusionPBX's
> official Debian installer** (`fusionpbx-install.sh`) — so the FreeSWITCH
> source build, PostgreSQL, FusionPBX app, schema, domain and admin user are
> exactly what the FusionPBX project tests — then applies the XCall layer
> (rebrand, admin panel, AI assistant, WebRTC softphone, AI agent) on top.
> It is designed to run on a **fresh Debian 12 VPS**; re-runs clean up
> partial state first.
>
> **Why is FreeSWITCH built from source?** The old public package repo
> (`files.freeswitch.org`) now requires a SignalWire login, and the public
> `pkg.signalwire.com` repo was retired — both return 401/404 anonymously.
> The installer's default is therefore a deterministic source build of
> **FreeSWITCH 1.10.12** (the `fusionpbx/freeswitch` fork), or the fast
> official repo when you pass `--signalwire-token`.
>
> **`mod_verto` note:** the source build omits `mod_verto`/`mod_signalwire`
> (they need the libks library, which does not build cleanly against
> FreeSWITCH 1.10.12) — the same modules FusionPBX's own source install
> disables. The XCall web softphone is unaffected: it registers over
> SIP-over-WebSocket (`mod_sofia`, 8081/8082, proxied by nginx `/verto`).
> If you need `mod_verto` for verto.js clients or FusionPBX's classic
> communicator, use `--signalwire-token` (the apt packages include it).

## What you get

| Component | Where |
|---|---|
| Portal (FusionPBX, rebranded XCall) | `https://<domain>/` |
| Admin panel (system/company, clients, softphone) | `https://<domain>/admin/` |
| AI assistant manager | `https://<domain>/ai-assistant/assistants.php` |
| Web softphone (in-browser, WebRTC) | `https://<domain>/webphone/` (log in first) |
| AI voice agent | `systemctl status xcall-agent` |
| FreeSWITCH | `systemctl status freeswitch` |
| Credentials saved to | `/opt/xcall/.deploy-state` |

## Connecting a local AI model

The AI Assistant page has a **"⚡ Detect local AI models"** button that probes
the PBX host for running servers and lists their models:

- **Ollama** — `http://127.0.0.1:11434` (native, no `/v1`)
- **LM Studio** — `http://127.0.0.1:1234/v1`
- **vLLM** — `http://127.0.0.1:8000/v1`
- **llama.cpp / LocalAI** — `http://127.0.0.1:8080/v1`

Install a local server on the same VPS, e.g. Ollama:

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull llama3.1
```

Then in the portal: **AI Assistants → Create → Local machine — Ollama →
⚡ Detect local AI models** → save. The agent will fetch that config and
converse with the caller using your local model.

## First login

1. Open `https://<domain>/` and log in as `admin` with your password.
2. Finish any one-time FusionPBX wizard prompts (domain, admin).
3. **Admin panel** (`/admin/`) → set your system name, company details,
   add clients, and customize the softphone.
4. **Accounts → Extensions** → create an extension for each agent, enable
   WebRTC, and they can dial from `/webphone/`.
5. **AI Assistants** → create an assistant, then route inbound calls to it
   (FusionPBX Inbound Routes → extension configured in the assistant's
   Handoff tab).

## Updating

```bash
cd /opt/xcall && sudo git pull
sudo bash deploy/bootstrap.sh   # idempotent — re-applies config
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `psql ... password authentication failed for user "fusionpbx"` on re-run | The official FusionPBX installer generated its own database password, which is **not** the `--db-pass` you pass. Resume mode now reuses the password already in `/etc/fusionpbx/config.conf` automatically. If it still fails, run `sudo -u postgres psql -c "ALTER ROLE fusionpbx WITH PASSWORD '<alphanumeric>'"` and re-run with `--db-pass '<alphanumeric>'`. |
| Fatal `Call to a member function beginTransaction() on null` on login | The `fusionpbx` role password no longer matches `/etc/fusionpbx/config.conf` (e.g. it was rotated out from under the portal). Repair and reload: `DBPW=$(sudo sed -n 's/^database\\.0\\.password[[:space:]]*=[[:space:]]*//p' /etc/fusionpbx/config.conf); sudo -u postgres psql -c "ALTER ROLE fusionpbx WITH PASSWORD '$DBPW';"` |
| Re-run switches the portal domain to the bare hostname | Resume mode now keeps the enabled domain row already in the database unless you pass `--domain` explicitly. |
| `certbot failed` | DNS A record must point at the server **before** running with `--email`. Re-run with the correct DNS or use `certbot --nginx -d <domain>` manually. |
| Portal shows "Unable to connect to database" | Check `/etc/fusionpbx/config.conf` password matches the DB: `sudo -u postgres psql -c "ALTER USER fusionpbx WITH PASSWORD '...'"`. |
| `configure: error: Library requirements ... not met` | A dev package is missing. On re-runs the installer installs everything, but if you build manually run: `apt-get install -y libpcre3-dev zlib1g-dev libjpeg-dev libldns-dev libssl-dev libsqlite3-dev libcurl4-openssl-dev libspeex-dev libspeexdsp-dev libpq-dev` then `rm -f /usr/src/freeswitch-1.10.12/config.cache`. |
| Softphone can't register | Open 8081/8082 (and 8083/8084 for verto.js clients) on the firewall; confirm the internal sofia profile binds `ws-binding`/`wss-binding` and nginx proxies `/verto` → `127.0.0.1:8081`. |
| Agent not answering | `sudo tail -f /opt/xcall/ai-agent/logs/xcall-agent.log` and confirm ESL password matches `event_socket.conf.xml`. |
| Local model not detected | The AI server must be running and reachable from the PBX host; press **Detect** again. |

## Bare-metal requirements

- Debian 12 (bookworm), 2 vCPU / 2 GB RAM minimum
  (4 GB+ if running a local LLM on the same box).
- Root access or a sudo user.
- Ports opened: 22, 80, 443, 5060 (udp/tcp), 5080, 8081, 8082, 8083, 8084,
  16384–16484/udp. The installer configures UFW automatically; adjust in your
  cloud's security group to match.
- For the default (source-built) FreeSWITCH: 4 GB RAM recommended (compiling
  on 2 GB works but is slower).

See `docs/SETUP.md` and `docs/VPS_HOSTING.md` for deep-dive operations.
