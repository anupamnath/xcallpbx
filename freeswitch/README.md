# XCall — FreeSWITCH configuration overlay

This directory contains the FreeSWITCH configuration files that XCall adds or
overrides. They are designed to be **overlaid on top of a stock FreeSWITCH
install** (Debian/Ubuntu packages or the official Docker image), replacing only
the files listed below.

## Layout

```
freeswitch/conf/
├── vars.xml                          # XCall global variables
├── autoload_configs/
│   ├── acl.conf.xml                  # ACLs (xcall.auto subnet)
│   ├── event_socket.conf.xml         # ESL for the AI agent
│   ├── modules.conf.xml              # module load list
│   └── verto.conf.xml                # verto.js endpoint (optional, 8083/8084)
├── dialplan/
│   ├── xcall_ai.xml                  # AI agent context (park + identify)
│   └── xcall_default.xml             # default context (specialist, internal)
├── directory/
│   └── xcall_users.xml               # users/extensions (e.g. specialist 7000)
└── sip_profiles/
    └── internal.xml                  # internal SIP profile (SIP-over-WS + WebRTC)
```

## Installation

### Option A — bare metal (Debian/Ubuntu + FreeSWITCH packages)

1. Install FreeSWITCH (see `deploy/install.sh`).
2. Copy the overlay into the FreeSWITCH conf dir:

   ```bash
   sudo cp -r freeswitch/conf/* /etc/freeswitch/
   sudo mkdir -p /etc/freeswitch/ssl
   ```

3. Generate the verto/WSS certificates:

   ```bash
   cd /etc/freeswitch/ssl
   openssl req -x509 -newkey rsa:2048 -keyout wss.key -out wss.pem \
       -days 365 -nodes -subj "/CN=xcall" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
   cat wss.pem > wss-chain.pem
   chown -R freeswitch:freeswitch /etc/freeswitch/ssl
   ```

4. Fix ownership of the AI agent spool dirs:

   ```bash
   sudo mkdir -p /var/spool/xcall/recordings /var/spool/xcall/tts
   sudo chown -R freeswitch:freeswitch /var/spool/xcall
   ```

5. Restart FreeSWITCH and verify:

   ```bash
   sudo systemctl restart freeswitch
   fs_cli -x "module_exists mod_verto"
   fs_cli -x "module_exists mod_event_socket"
   fs_cli -x "sofia status"
   ```

### Option B — Docker

See `docker/` for the compose stack. The overlay is copied into the FreeSWITCH
image at build time and the spool dirs are mounted as volumes.

## Wiring the AI agent

1. Run the AI agent (see `ai-agent/README.md`). It connects to ESL (8021) and
   waits for `CHANNEL_PARK` in the `xcall_ai` context.
2. Dial extension `${xcall_ai_extension}` (5000) from the web softphone to test
   the agent directly.
3. Route your inbound trunk/DID to the `xcall_ai` context (or the 5000
   extension) so real calls reach the bot.
4. At the script's handoff node, the agent runs `uuid_transfer` to
   `${xcall_specialist_extension}` (7000), which rings the specialist's web
   softphone.

## Notes

- The `internal.xml` profile enables ICE/DTLS-SRTP so WebRTC clients can
  register. The verto profile serves the web softphone on 8081 (ws) / 8082
  (wss).
- The `xcall_ai` context uses `park` — the AI agent (not the dialplan) decides
  what to play. If the agent is down, calls park silently; add a failover
  extension (e.g. to voicemail) if desired.
- Change all passwords (ESL, extension passwords) before exposing the server.
