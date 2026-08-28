# XCall — Setup Guide

Choose one path:

- **A. Docker** (recommended for evaluation) — everything runs in containers.
- **B. Bare metal** (recommended for production) — native FreeSWITCH + FusionPBX
  on Ubuntu/Debian.

Both end with the same thing: an XCall portal at `https://<host>/` and a web
softphone at `/webphone/` for every logged-in agent.

---

## A. Docker

### Prerequisites
- Docker Engine + Docker Compose plugin.
- A hostname/DNS entry for your server (`X_DOMAIN`, default `xcall.local`).
- Ports open: 80/443 (web), 5060/5080 (SIP), 8081/8082 (verto), 8021 (ESL),
  16384–16484/udp (RTP).

### Steps

```bash
cd docker
cp .env.example .env          # set DB_PASSWORD, FUSIONPBX_ADMIN_PASSWORD, ...
docker compose up -d --build
```

1. **First run of the portal**: complete the FusionPBX web installer at
   `https://<host>/` (create the admin account).
2. **Apply the XCall PBX brand** (if not auto-applied): the portal entrypoint
   runs `xcall_rebrand.sql` on boot. Verify in **Settings → Theme** that
   `custom_css = /themes/default/images/xcall.css` and `menu_brand_text =
   XCall PBX`. To use your own name/logo, open the **Admin Panel → System &
   Company** and upload a logo (saved under `/resources/xcall_brand/`).
3. **Create the specialist**: in the portal add extension `7000` and a user
   linked to it, WebRTC enabled.
4. **Check the AI agent**: `docker compose logs ai-agent` should show
   "ESL connected". The agent uses the `stub` STT/TTS by default — see
   `docs/AI_AGENT.md` to enable local whisper/piper/ollama.
5. **Test the bot**: log into the portal as an agent, open `/webphone/`, dial
   `5000` — the bot should answer and run the triage script, then transfer to
   `7000`.

---

## B. Bare metal (Ubuntu 22.04 / Debian 12)

```bash
sudo bash deploy/install.sh
```

The script:

1. Installs FreeSWITCH + FusionPBX via the official installer.
2. Applies the XCall FreeSWITCH overlay (`freeswitch/conf/`).
3. Generates TLS certs for verto (WSS).
4. Rebranks the portal (`portal/rebrand/install-rebrand.sh`).
5. Installs the AI agent as a systemd service (`xcall-agent.service`) with a
   Python venv.
6. Prints the finishing steps.

Then, manually:

```bash
# dialplan reload
fs_cli -x "reloadxml"
fs_cli -x "reload mod_verto"

# check services
systemctl status freeswitch xcall-agent nginx php-fpm
```

---

## Post-install checklist (both paths)

| Step | Where |
|------|-------|
| Complete portal installer | first visit to `https://<host>/` |
| Set theme `custom_css` + `menu_brand_text` | Settings → Theme |
| Create specialist ext `7000` (WebRTC) | Extensions → add |
| Create agent user(s) linked to extensions | Users → add |
| Route inbound trunk/DID to `xcall_ai` | Dialplan Inbound |
| Verify ESL password matches agent config | `event_socket.conf.xml` vs `config.yaml` |
| Enable the AI engines (optional) | see `docs/AI_AGENT.md` |

## Verification commands

```bash
# FreeSWITCH healthy?
fs_cli -x "status"
fs_cli -x "sofia status profile internal"
fs_cli -x "module_exists mod_verto"
fs_cli -x "module_exists mod_event_socket"

# ESL reachable for the agent?
echo "auth ClueCon" | timeout 3 nc 127.0.0.1 8021

# Agent logs
journalctl -u xcall-agent -f        # bare metal
docker compose logs -f ai-agent     # docker

# Agent unit tests (on any machine)
cd ai-agent && python -m unittest discover -s tests -v
```
