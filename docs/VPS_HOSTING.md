# XCall — VPS Hosting Guide

This guide takes you from a bare Ubuntu VPS to a production XCall PBX with the
AI Assistant portal, WebRTC softphone, and AI voice agent. **Yes, this is
designed to be hosted on a VPS.**

---

## 1. Choose a VPS

Recommended baseline:

| Component | Minimum | Comfortable |
|---|---|---|
| vCPU | 2 | 4 |
| RAM | 4 GB | 8 GB |
| Disk | 40 GB SSD | 80 GB SSD |
| Bandwidth | 1 Gbps unmetered-ish | — |

Why 4 GB+ RAM: FreeSWITCH is light, but local STT (Whisper) and local LLM
(Ollama) want RAM. If you use **cloud LLMs (API key)** you can stay at 2 GB.

Providers: any standard VPS (Vultr, DigitalOcean, Hetzner, Linode, Contabo…).
Pick Ubuntu **22.04 LTS** or **24.04 LTS** (the FusionPBX installer targets it).

A **static public IP** is required. Add a DNS A record, e.g. `pbx.example.com
→ <your-ip>` (and an AAAA record if IPv6).

---

## 2. Secure the server first

SSH in as root, then:

```bash
# update everything
apt update && apt upgrade -y

# create a non-root admin user
adduser admin
usermod -aG sudo admin
cp -r ~/.ssh /home/admin/ && chown -R admin:admin /home/admin/.ssh

# harden ssh
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
```

Install a firewall **before** exposing anything:

```bash
apt install -y ufw fail2ban
ufw allow OpenSSH
ufw allow 80,443/tcp
ufw allow 5060,5080/udp     # SIP
ufw allow 5060,5080/tcp
ufw allow 8081,8082/tcp     # verto (WebRTC websocket)
ufw allow 8021/tcp          # ESL (restrict to your IPs if possible)
ufw allow 16384:16484/udp   # RTP media
ufw --force enable
```

> Restrict 8021 and 8081/8082 to trusted IPs if you know them:
> `ufw allow from <your-ip> to any port 8021`.

---

## 3. Install the system

### Option A — Docker (recommended for quick start)

```bash
apt install -y docker.io docker-compose-plugin
cd /opt && git clone <your-xcall-repo> xcall && cd xcall/docker
cp .env.example .env
# edit .env: set DB_PASSWORD, FUSIONPBX_ADMIN_PASSWORD, X_DOMAIN=pbx.example.com
docker compose up -d --build
```

### Option B — Bare metal (recommended for long-term production)

```bash
apt install -y git wget
cd /opt && git clone <your-xcall-repo> xcall && cd xcall
sudo bash deploy/install.sh
```

Either way, after install:

1. Visit `https://pbx.example.com/` and complete the FusionPBX web installer.
2. Run the AI assistant schema (bare metal):
   `psql -U fusionpbx -d fusionpbx -f portal/ai-assistant/schema.sql`
3. Configure the AI agent (see below).

---

## 4. TLS with Let's Encrypt (production cert)

The default setup uses a self-signed cert. For a public host, get a real cert:

```bash
apt install -y certbot python3-certbot-nginx
certbot --nginx -d pbx.example.com
```

For Docker, add a `caddy` service (which auto-provisions Let's Encrypt) or run
certbot on the host and mount the certs into nginx. Simplest production setup:

```bash
# stop nginx briefly, issue cert, restart
certbot certonly --standalone -d pbx.example.com
# then point nginx at /etc/letsencrypt/live/pbx.example.com/{fullchain.pem,privkey.pem}
```

After that, turn on HSTS only once the cert is valid (the nginx config already
sends it — revert if you keep self-signed).


---

## 5. Configure the AI agent

Create `/opt/xcall/ai-agent/config.yaml`:

```yaml
agent:
  context: "xcall_ai"
  identify_var: "xcall_agent"
  identify_value: "true"
  mode: "assistant"                     # use the portal assistant, not the script

assistant:
  portal_url: "https://pbx.example.com/ai-assistant/assistant_api.php"
  portal_secret: "<secret from v_xcall_settings>"

stt:
  engine: "whisper"   # or vosk / stub
  model: "base"
tts:
  engine: "piper"     # or espeak / stub
  piper_path: "piper"
  piper_model: "/opt/xcall/ai-agent/models/en_US-lessac-medium.onnx"
llm:
  engine: "none"      # the assistant's own model provider handles the LLM
```

Get the secret:

```bash
psql -U fusionpbx -d fusionpbx -tAc \
  "select setting_value from v_xcall_settings where setting_name='agent_shared_secret'"
```

Restart the agent:

```bash
# bare metal
systemctl restart xcall-agent
# docker
docker compose -f docker/docker-compose.yml restart ai-agent
```

Check it connected:

```bash
journalctl -u xcall-agent -f        # bare metal
docker compose logs -f ai-agent     # docker
# you should see: "ESL connected" + "assistant mode ready: ..."
```

---

## 6. Point inbound calls at the assistant

1. Buy / configure a DID + SIP trunk (FusionPBX: Gateways) — or use only
   internal extensions for testing.
2. In the portal: **Dialplan → Inbound**, route your inbound number to
   extension `5000` (the AI agent context) or set the context to `xcall_ai`.
3. Agents register via the portal web softphone (`/webphone/`).


---

## 7. Daily operations

### Backups (non-negotiable)

Back up the **database**, **FreeSWITCH config**, **recordings**, and the
**encryption key** (`resources/xcall_secrets.php` — without it saved API keys
are unrecoverable):

```bash
# db
pg_dump -U fusionpbx fusionpbx | gzip > /var/backups/xcall/db-$(date +%F).sql.gz
# secrets + config
cp /var/www/fusionpbx/resources/xcall_secrets.php /var/backups/xcall/
tar czf /var/backups/xcall/fs-$(date +%F).tar.gz /etc/freeswitch /var/spool/xcall
# keep last 14 days
find /var/backups/xcall -mtime +14 -delete
```

Put this in a cron/systemd timer. Optionally push to an off-site bucket.

### Monitoring

```bash
systemctl status freeswitch xcall-agent nginx php-fpm 2>/dev/null
fs_cli -x "status"
fs_cli -x "show channels count"
```

Alert on: agent down, FreeSWITCH down, disk > 85%, DB reachability.

### OS updates

```bash
apt update && apt upgrade -y      # then reboot weekly
```

---

## 8. Production hardening checklist

- [ ] Non-root user; SSH keys only; root login disabled.
- [ ] UFW enabled with only needed ports; 8021 restricted.
- [ ] Real TLS cert; HSTS on.
- [ ] All default passwords changed (FusionPBX admin, ESL `ClueCon`, DB).
- [ ] `event_socket.conf.xml` password rotated + matching agent config.
- [ ] nginx rate limits + security headers (already in `xcall.conf`).
- [ ] `resources/xcall_secrets.php` permissions `600`, backed up.
- [ ] Backups running (DB, config, recordings, secrets) + off-site copy.
- [ ] fail2ban active for ssh + nginx.
- [ ] Auto-restart on boot for all services (Docker `restart: unless-stopped`,
      bare metal systemd `enable`).

---

## 9. Scaling / capacity notes

- **Concurrency**: one AI agent process handles calls sequentially per call
  (each call = one conversation thread). For heavy call volume, run multiple
  agent instances across extension ranges, or add a second node.
- **Local LLM**: if you run Ollama on the same box, give the VM 8 GB+ RAM or
  put Ollama on a separate machine and point the assistant's base URL at it.
- **Recordings**: grow on disk fast; set retention + offload to S3.
- **RTP**: keep 16384–16484/udp open and open `rtp-ip` to the VPS's public IP
  if clients are remote.

---

## 10. Troubleshooting on a VPS

| Symptom | Check |
|---|---|
| Can't register softphone | Is 8081/8082 open? Is the page HTTPS? (`getUserMedia` needs a secure context). |
| Calls route to agent but silence | Is the agent connected to ESL? Are STT/TTS engines actually installed? |
| "assistant mode ready" but no LLM | Confirm `assistant_provider`/key in the portal; test the URL from the server (`curl https://api.openai.com/v1/models -H "Authorization: Bearer ..."`). |
| Local Ollama not reachable | Ollama must bind `0.0.0.0` (`OLLAMA_HOST=0.0.0.0`) and the VPS firewall must allow its port. |
| Media one-way / NAT issues | Set `ext-rtp-ip` / `ext-sip-ip` to the VPS public IP in `vars.xml`. |
| Agent crashes on startup | `python -m xcall_agent --config config.yaml --dry-run` to validate config. |

