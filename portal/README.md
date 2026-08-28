# XCall Portal

The XCall portal is a **rebranded FusionPBX** with an added in-browser
softphone. It is what "clients run on web login itself" means: an agent logs
into the portal in a browser and gets a WebRTC phone with no desktop app.

## What's here

```
portal/
├── webphone/                 # in-portal WebRTC softphone (SIP.js)
│   ├── index.html            # softphone UI
│   ├── app.js                # SIP.js client
│   ├── style.css
│   ├── config.php            # session-guarded SIP config endpoint
│   └── vendor/sip.min.js     # vendored SIP.js (offline-friendly)
├── assets/
│   ├── logo.svg              # XCall logo
│   ├── favicon.svg           # XCall favicon
│   └── xcall.css             # XCall brand stylesheet (injected via theme)
└── rebrand/
    ├── install-rebrand.sh    # one-shot rebrand installer
    └── xcall_rebrand.sql     # brand settings (name, colors, footer)
```

## Installing (on the PBX server)

1. Install FusionPBX normally (see `deploy/install.sh` / official installer).
2. Run the rebrand installer:

   ```bash
   sudo bash portal/rebrand/install-rebrand.sh /var/www/fusionpbx
   ```

3. In the portal: **Settings → Theme** → set `custom_css` to
   `/themes/default/images/xcall.css` and `menu_brand_text` to `XCall PBX`.
4. Create a user + extension for each agent, enable WebRTC, and they can dial
   from `/webphone/` right after login.

## Optimization

The portal is stock FusionPBX plus a few performance tweaks:

- **Custom CSS instead of a theme fork** — survives FusionPBX upgrades.
- **Vendored SIP.js** — no CDN, no third-party network calls.
- **Cache-friendly CSS** (`css.php` sends `Cache-Control: public, max-age=3600`).
- See `deploy/nginx.conf` for gzip, static caching, HTTP/2, and TLS settings.

## Branding notes

FusionPBX stores branding in the database (`v_default_settings` category
`theme`), so the rebrand is mostly data, not code:

- `menu_brand_type` — `text`, `image`, or `image_text`; `image_text` shows the
  logo + name.
- `menu_brand_text` / `product_name` — the name shown in the menu bar (XCall PBX).
- `menu_brand_image` / `logo_login` / `logo_header` — image paths for the menu
  bar, login page and header.
- `favicon` — the browser tab icon.
- `footer` — the text in the footer.
- `custom_css` — an extra stylesheet appended to every page.

The **Admin Panel → System & Company** page writes these values (name, colors,
logo) into `v_default_settings` automatically, and lets an admin **upload a
custom logo** (stored in `/resources/xcall_brand/`).

The `xcall_rebrand.sql` updates all of these. If a setting name differs in your
FusionPBX version, set it once in the portal UI and export it — the concept is
identical.

## WebRTC / softphone requirements

- Portal served over **HTTPS** (WebRTC requires a secure context). See
  `deploy/nginx.conf` for a working TLS config, or use `localhost` in dev.
- FreeSWITCH must expose a WebRTC endpoint (`mod_verto` on 8081/8082, or a SIP
  over WSS profile). See `freeswitch/conf/autoload_configs/verto.conf.xml`.
- Each agent needs a SIP user with a password (created in the portal). The
  softphone's `config.php` reads the logged-in user's credentials from the
  portal session — no password is ever typed into the softphone itself.
