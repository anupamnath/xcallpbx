#!/usr/bin/env bash
# XCall — portal entrypoint wrapper.
#
# Runs the stock FusionPBX entrypoint, then waits for the DB and applies the
# XCall branding SQL. The FusionPBX base image starts postgres + php-fpm +
# nginx via its own supervisord/start script.
set -euo pipefail

# defer to the stock entrypoint (it stays in the foreground)
/usr/local/bin/entrypoint.sh 2>/dev/null &
STOCK_PID=$!

# give postgres time to come up, then rebrand
for i in $(seq 1 30); do
    if pg_isready -q -U postgres -d fusionpbx 2>/dev/null; then
        break
    fi
    sleep 2
done

echo "[xcall] applying branding"
psql -U postgres -d fusionpbx \
    -f /var/www/fusionpbx/themes/default/images/xcall_rebrand.sql \
    2>/dev/null \
    || echo "[xcall] branding SQL skipped (table/keys differ — set values in Settings > Theme)"

# re-write the custom_css theme setting regardless
psql -U postgres -d fusionpbx -q <<'SQL' 2>/dev/null || true
UPDATE v_default_settings SET default_setting_value='/themes/default/images/xcall.css'
 WHERE default_setting_category='theme' AND default_setting_subcategory='custom_css';
UPDATE v_default_settings SET default_setting_value='XCall'
 WHERE default_setting_category='theme' AND default_setting_subcategory='menu_brand_text';
SQL

# apply the AI assistant schema (idempotent)
psql -U postgres -d fusionpbx -f /var/www/fusionpbx/ai-assistant/schema.sql 2>/dev/null \
    && echo "[xcall] AI assistant schema applied" \
    || echo "[xcall] AI assistant schema skipped"

wait "$STOCK_PID"
