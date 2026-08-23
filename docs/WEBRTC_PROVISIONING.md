# XCall — WebRTC Provisioning & Web Softphone

## Concept

Agents register from their **browser** after logging into the XCall portal —
no softphone app, no manual config. This is "WebRTC provisioning" in the
simplest possible form: the portal already knows the user's SIP credentials, so
the softphone just needs the WebSocket endpoint.

## How registration works

1. Agent logs into `https://<host>/`.
2. Opens `/webphone/` (same origin, same session).
3. `config.php` reads the session → returns the user's `username`, `password`,
   `extension`, `domain`, and the verto WSS URL.
4. SIP.js (vendored) creates a `SIP.UA`, registers to FreeSWITCH over WSS, and
   shows "Ready — <extension>".

## Enabling WebRTC on the server

### FreeSWITCH
- `mod_verto` must be loaded (`autoload_configs/modules.conf.xml`).
- `autoload_configs/verto.conf.xml` binds ws on 8081 and wss on 8082.
- Certificates for wss: the container entrypoint generates self-signed certs;
  bare metal: `deploy/install.sh` does the same under `/etc/freeswitch/tls`.
- The internal SIP profile (`sip_profiles/internal.xml`) enables ICE + DTLS-SRTP
  so WebRTC media works.

### TLS / reverse proxy
- WebRTC (getUserMedia) requires a **secure context**.
- The Docker stack terminates TLS at nginx and proxies `/verto` as WSS.
- Bare metal: serve the portal over HTTPS (nginx + certbot, or a LAN CA), or
  use `http://localhost` during development.

## Creating agent users

1. Portal → **Extensions → Add** — e.g. extension `7001`, name "Agent One",
   enable WebRTC.
2. Portal → **Users → Add** — username `agent1`, set the password, link to
   extension `7001` (role: agent).
3. Log in as `agent1`, open `/webphone/`, allow microphone access.

## The specialist (AI handoff target)

- Create extension `7000` (the AI script's handoff destination).
- Log in as that user and keep `/webphone/` open in a browser.
- When the AI bot says "please hold", FreeSWITCH transfers the call to `7000`
  → the specialist's softphone rings → they pick up and continue the call.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| "Registration failed" | Wrong SIP password; or WSS endpoint unreachable. Check `fs_cli -x "verto_contact <ext>"`. |
| Microphone blocked | Browser site settings → allow mic for the portal origin. |
| `config.php` returns 401 | Not logged into the portal. |
| WebRTC "insecure context" | Portal not served over HTTPS (or not localhost). |
| No audio both ways | RTP ports 16384-16484/udp blocked; NAT issues — set `ext-rtp-ip`. |
| Calls to 5000 park silently | AI agent not running, or ESL password mismatch. |

## Provisioning other devices (optional)

For real SIP phones or mobile clients, FusionPBX's **Device / Provision**
apps can auto-provision Yealink/Grandstream/... devices. The web softphone is
only one option — the same extensions work from any SIP client.
