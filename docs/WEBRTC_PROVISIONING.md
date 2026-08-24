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
   `extension`, `domain`, and the WebSocket URL (over HTTPS it is the
   same-origin `/verto` path, TLS-terminated by nginx).
4. SIP.js (vendored) creates a `SIP.UA`, registers to FreeSWITCH over WSS, and
   shows "Ready — <extension>".

## Enabling WebRTC on the server

### FreeSWITCH
- The web softphone is **SIP.js** and registers with **SIP over WebSocket**
  (RFC 7118), which `mod_sofia` serves directly: the internal SIP profile
  (`sip_profiles/internal.xml`) binds `ws` on 8081 and `wss` on 8082
  (`ws-binding` / `wss-binding`).
- `mod_verto` (the verto.js JSON protocol, used by FusionPBX's communicator)
  is optional and binds 8083/8084 (`autoload_configs/verto.conf.xml`). It is
  only available when FreeSWITCH is installed from the package repos
  (`--signalwire-token`); the source-built FreeSWITCH omits it because it
  requires the libks library (see `docs/VPS_DEPLOY.md`).
- Certificates for the direct `wss://host:8082` endpoint: the container
  entrypoint / `deploy` scripts generate self-signed certs under
  `/etc/freeswitch/tls`. The browser path that matters goes through the portal
  reverse proxy (see below) so it uses the trusted portal certificate instead.
- The internal SIP profile also enables ICE + DTLS-SRTP so WebRTC media works.

### TLS / reverse proxy
- WebRTC (getUserMedia) requires a **secure context**.
- The Docker stack and the bare-metal provisioner terminate TLS at nginx and
  proxy `/verto` to FreeSWITCH's SIP-over-WebSocket listener (8081), so the
  browser always talks to a trusted certificate.
- During development `http://localhost` is also a secure context.

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
| "Registration failed" | Wrong SIP password; or the WebSocket endpoint is unreachable. Check `fs_cli -x "sofia status profile internal"` and that nginx proxies `/verto` → 8081. |
| Microphone blocked | Browser site settings → allow mic for the portal origin. |
| `config.php` returns 401 | Not logged into the portal. |
| WebRTC "insecure context" | Portal not served over HTTPS (or not localhost). |
| No audio both ways | RTP ports 16384-16484/udp blocked; NAT issues — set `ext-rtp-ip`. |
| Calls to 5000 park silently | AI agent not running, or ESL password mismatch. |

## Provisioning other devices (optional)

For real SIP phones or mobile clients, FusionPBX's **Device / Provision**
apps can auto-provision Yealink/Grandstream/... devices. The web softphone is
only one option — the same extensions work from any SIP client.
