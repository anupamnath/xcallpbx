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
# prefer PNG if provided by the operator (uncomment when you add them):
# install -m 644 "$ASSETS/logo_login.png" "$IMG_DIR/logo_login.png"
# install -m 644 "$ASSETS/logo_header.png" "$IMG_DIR/logo_header.png"

# 2. custom stylesheet -------------------------------------------------- #
install -m 644 "$ASSETS/xcall.css" "$IMG_DIR/xcall.css"
echo "   copied brand assets + xcall.css"

# 3. branding SQL ------------------------------------------------------ #
echo "   applying branding SQL (postgres user: $DB_USER) ..."
psql -h 127.0.0.1 -U "$DB_USER" -f "$SCRIPT_DIR/xcall_rebrand.sql" fusionpbx \
  || echo "   WARNING: SQL apply failed — set brand values in the portal UI (Settings > Theme)."

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
chown -R www-data:www-data "$FUSIONPBX_DIR/webphone" "$FUSIONPBX_DIR/ai-assistant" "$FUSIONPBX_DIR/admin" "$IMG_DIR/xcall.css" 2>/dev/null || true

echo
echo "Done. Next steps:"
echo "  1. Login to the portal -> Settings -> Theme and set:"
echo "       custom_css      = /themes/default/images/xcall.css"
echo "       menu_brand_text = XCall"
echo "       footer          = Powered by XCall"
echo "  2. Set the domain name / brand logo if you want PNG instead of SVG."
echo "  3. Open /webphone/ after logging in to use the in-browser softphone."
