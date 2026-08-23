# XCall Web Softphone (in-portal)

A WebRTC softphone embedded in the XCall portal. **Clients use the portal login
itself** — no desktop app. Once a user logs into XCall, they open
`/webphone/` and get a browser softphone registered to FreeSWITCH.

## Files

```
webphone/
├── index.html        # the softphone UI
├── app.js            # SIP.js client logic
├── style.css         # UI theme
├── config.php        # serves SIP credentials to the browser (session-guarded)
└── vendor/
    ├── sip.min.js    # vendored SIP.js 0.15.11 (UMD browser build)
    └── fetch-sipjs.sh# re-download sip.js if needed
```

## Install into the portal

1. Copy the `webphone/` directory into the FusionPBX web root:

   ```bash
   cp -r portal/webphone /var/www/fusionpbx/webphone
   chown -R www-data:www-data /var/www/fusionpbx/webphone
   ```

   (Adjust the web root path to your FusionPBX install.)

2. Ensure the portal session has a SIP user. `config.php` reads the current
   `$_SESSION['username']` and looks up that user's password in `v_users`, so
   the extension must exist and have a password (create it in the portal:
   Extensions → add extension, then Users → add user and link them).

3. Visit `https://<server>/webphone/` after logging into the portal.

## How it works

- `config.php` returns `{username, password, extension, domain, ws}` for the
  logged-in user. It derives the WebSocket URL (`ws://…:8081` or
  `wss://…:8082`) from the domain settings (verto ports) and whether the page
  was served over HTTPS.
- `app.js` uses SIP.js 0.15.11 with `SIP.UA` over `WebSocket` (the verto /
  SIP-over-WSS endpoint of FreeSWITCH). Register → dial → answer/hang up/mute/
  hold. Incoming calls (e.g. the AI agent's handoff) ring in the browser.
- WebRTC requires a **secure context**: serve the portal over HTTPS, or use
  `http://localhost` during development. The browser must also be allowed to
  use the microphone.

## Enabling the specialist to receive AI-agent handoffs

The default AI script transfers to extension `7000`. Create user `7000` in the
portal with WebRTC enabled, log in as that user, open `/webphone/`, and the
incoming transfer rings in the browser. See `docs/AI_AGENT.md`.

## Troubleshooting

- **Registration failed**: check the FreeSWITCH verto/WS endpoint is reachable
  and the user's SIP password matches. Verify with:
  `fs_cli -x "verto_contact 7000"` after registering.
- **Microphone permission**: check the browser site settings.
- **config.php 401**: you must be logged into the XCall portal first.
- **Verto vs plain WS**: if your deployment disables verto, set the internal
  profile's `wss-binding` and point `ws` at it (see `freeswitch/conf`).
