#!/usr/bin/env bash
# XCall — rebrand installer for a FusionPBX deployment.
#
# Applies the XCall branding to a FusionPBX web root:
#   1. copies the XCall logo/favicon over the default theme images
#   2. copies xcall.css into the theme dir
#   3. applies the branding SQL (name, footer, palette, custom_css setting)
#   4. drops the XCall web softphone into the portal
#
# Usage:
#   sudo ./install-rebrand.sh /var/www/fusionpbx [postgres_db_user]
#
# Then set the "custom_css" theme setting via the portal if the SQL
# update did not find the setting row (some versions name it differently).

set -euo pipefail

FUSIONPBX_DIR="${1:-/var/www/fusionpbx}"
DB_USER="${2:-fusionpbx}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$SCRIPT_DIR/../assets"
WEBPHONE="$SCRIPT_DIR/../webphone"

if [ ! -f "$FUSIONPBX_DIR/index.php" ]; then
    echo "error: $FUSIONPBX_DIR does not look like a FusionPBX web root" >&2
    exit 1
fi

echo "== XCall rebrand: $FUSIONPBX_DIR"

# 1. logos + favicon --------------------------------------------------- #
IMG_DIR="$FUSIONPBX_DIR/themes/default/images"
mkdir -p "$IMG_DIR"
install -m 644 "$ASSETS/logo.svg"        "$IMG_DIR/xcall_logo.svg"
install -m 644 "$ASSETS/favicon.svg"     "$IMG_DIR/xcall_favicon.svg"
# Also overwrite the stock FusionPBX logo filenames with the XCall logo, so the
# login page / menu bar / side menu change even if a given FusionPBX version
# reads one of these fixed names (or a hard-coded path) instead of the
# logo_login / menu_brand_image settings.
install -m 644 "$ASSETS/logo.svg"        "$IMG_DIR/logo.png"
install -m 644 "$ASSETS/logo.svg"        "$IMG_DIR/logo_login.png"
install -m 644 "$ASSETS/logo.svg"        "$IMG_DIR/logo_header.png"
install -m 644 "$ASSETS/logo.svg"        "$IMG_DIR/logo_side_contracted.png"
install -m 644 "$ASSETS/logo.svg"        "$IMG_DIR/logo_side_expanded.png"
install -m 644 "$ASSETS/favicon.svg"     "$IMG_DIR/favicon.ico"

# 2. custom stylesheet -------------------------------------------------- #
install -m 644 "$ASSETS/xcall.css" "$IMG_DIR/xcall.css"
echo "   copied brand assets + xcall.css"

# 3. branding SQL ------------------------------------------------------ #
echo "   applying branding SQL (postgres user: $DB_USER) ..."
if ! psql -h 127.0.0.1 -U "$DB_USER" -f "$SCRIPT_DIR/xcall_rebrand.sql" fusionpbx; then
    echo "   !! branding SQL FAILED — the login logo / menu name will NOT have changed." >&2
    echo "      Fix: export PGPASSWORD=<fusionpbx_database_password> and re-run, e.g.:" >&2
    echo "        PGPASSWORD='<pass>' PGHOST=127.0.0.1 bash $0 $FUSIONPBX_DIR $DB_USER" >&2
    echo "      (see /opt/xcall/.deploy-state if the installer generated the password)" >&2
fi

# 3b. add the "Admin Panel" entry below "Advanced" in the left sidebar ----- #
if [ -f "$SCRIPT_DIR/admin_menu.sql" ]; then
    echo "   adding 'Admin Panel' to the left sidebar menu ..."
    if ! psql -h 127.0.0.1 -U "$DB_USER" -f "$SCRIPT_DIR/admin_menu.sql" fusionpbx; then
        echo "   !! could not add the Admin Panel menu item (DB/table mismatch?)." >&2
        echo "      The panel still works at: https://<host>/admin/" >&2
        echo "      Run it manually: PGPASSWORD='<pass>' psql -h 127.0.0.1 -U fusionpbx -f $SCRIPT_DIR/admin_menu.sql fusionpbx" >&2
    fi
fi

# 3c. enable WebRTC in the DB (ws-binding on the internal profile + web_rtc flag) #
echo "   enabling WebRTC (ws-binding on the internal SIP profile) ..."
psql -h 127.0.0.1 -U "$DB_USER" -d fusionpbx -q <<'SQL' 2>/dev/null || true
INSERT INTO v_sip_profile_settings
    (sip_profile_setting_uuid, sip_profile_uuid, sip_profile_setting_name, sip_profile_setting_value, sip_profile_setting_enabled, sip_profile_setting_description)
SELECT gen_random_uuid(), p.sip_profile_uuid, 'ws-binding', ':8081', true, 'XCall web softphone (SIP over WebSocket)'
  FROM v_sip_profiles p
 WHERE p.sip_profile_name = 'internal'
   AND NOT EXISTS (SELECT 1 FROM v_sip_profile_settings s WHERE s.sip_profile_uuid=p.sip_profile_uuid AND s.sip_profile_setting_name='ws-binding');
INSERT INTO v_sip_profile_settings
    (sip_profile_setting_uuid, sip_profile_uuid, sip_profile_setting_name, sip_profile_setting_value, sip_profile_setting_enabled, sip_profile_setting_description)
SELECT gen_random_uuid(), p.sip_profile_uuid, 'wss-binding', ':8082', true, 'XCall web softphone (SIP over WebSocket TLS)'
  FROM v_sip_profiles p
 WHERE p.sip_profile_name = 'internal'
   AND NOT EXISTS (SELECT 1 FROM v_sip_profile_settings s WHERE s.sip_profile_uuid=p.sip_profile_uuid AND s.sip_profile_setting_name='wss-binding');
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT gen_random_uuid(), 'domain', 'web_rtc_enabled', 'true'
 WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='domain' AND default_setting_subcategory='web_rtc_enabled');
SQL

# 4. web softphone ----------------------------------------------------- #
install -d "$FUSIONPBX_DIR/webphone/vendor"
install -m 644 "$WEBPHONE/index.html" "$FUSIONPBX_DIR/webphone/index.html"
install -m 644 "$WEBPHONE/app.js"     "$FUSIONPBX_DIR/webphone/app.js"
install -m 644 "$WEBPHONE/style.css"  "$FUSIONPBX_DIR/webphone/style.css"
install -m 644 "$WEBPHONE/config.php" "$FUSIONPBX_DIR/webphone/config.php"
install -m 644 "$WEBPHONE/vendor/sip.min.js" "$FUSIONPBX_DIR/webphone/vendor/sip.min.js"
echo "   installed web softphone at /webphone"

# 5. AI assistant manager ---------------------------------------------- #
AIASSISTANT="$SCRIPT_DIR/../ai-assistant"
if [ -d "$AIASSISTANT" ]; then
    install -d "$FUSIONPBX_DIR/ai-assistant"
    install -m 644 "$AIASSISTANT"/*.php    "$FUSIONPBX_DIR/ai-assistant/"
    install -m 644 "$AIASSISTANT"/*.css    "$FUSIONPBX_DIR/ai-assistant/"
    install -m 644 "$AIASSISTANT"/*.js     "$FUSIONPBX_DIR/ai-assistant/"
    echo "   installed AI assistant manager at /ai-assistant"
    if command -v psql >/dev/null 2>&1; then
        psql -h 127.0.0.1 -U "$DB_USER" -f "$AIASSISTANT/schema.sql" fusionpbx \
          && echo "   applied AI assistant schema" \
          || echo "   WARNING: AI assistant schema not applied (run schema.sql manually)"
    fi
fi

# 6. admin panel ------------------------------------------------------- #
ADMIN="$SCRIPT_DIR/../admin"
if [ -d "$ADMIN" ]; then
    install -d "$FUSIONPBX_DIR/admin"
    install -m 644 "$ADMIN"/*.php "$FUSIONPBX_DIR/admin/"
    install -m 644 "$ADMIN"/*.css "$FUSIONPBX_DIR/admin/"
    install -m 644 "$ADMIN"/*.js  "$FUSIONPBX_DIR/admin/"
    echo "   installed admin panel at /admin"
fi

# 7. permissions ------------------------------------------------------- #
# make the logo upload dir writable by the web server (created by the admin
# panel when a logo is uploaded; created here too so chown can reach it)
mkdir -p "$FUSIONPBX_DIR/resources/xcall_brand" 2>/dev/null || true
chown -R www-data:www-data "$FUSIONPBX_DIR/webphone" "$FUSIONPBX_DIR/ai-assistant" "$FUSIONPBX_DIR/admin" "$FUSIONPBX_DIR/resources/xcall_brand" "$IMG_DIR/xcall.css" 2>/dev/null || true

echo
echo "Done. Next steps:"
echo "  1. Login to the portal -> Settings -> Theme and set:"
echo "       custom_css      = /themes/default/images/xcall.css"
echo "       menu_brand_text = XCall PBX"
echo "       footer          = Powered by XCall PBX"
echo "       menu_brand_type = image_text   (shows the logo in the menu bar)"
echo "  2. Use Admin Panel -> System & Company to set your company details and"
echo "     upload a custom logo (saved under /resources/xcall_brand/)."
echo "  3. Open /webphone/ after logging in to use the in-browser softphone."
