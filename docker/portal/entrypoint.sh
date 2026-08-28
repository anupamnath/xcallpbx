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

# Force the XCall PBX brand values regardless (works even if the .sql above is absent).
# First UPDATE existing rows, then INSERT the ones that do not yet exist, so the
# name + logo always land (a plain UPDATE silently no-ops on a missing row).
psql -U postgres -d fusionpbx -q <<'SQL' 2>/dev/null || true
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'b0000001-0000-0000-0000-000000000001','theme','custom_css','/themes/default/images/xcall.css'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='custom_css');
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'b0000001-0000-0000-0000-000000000002','theme','menu_brand_text','XCall PBX'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='menu_brand_text');
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'b0000001-0000-0000-0000-000000000003','theme','product_name','XCall PBX'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='product_name');
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'b0000001-0000-0000-0000-000000000004','theme','menu_brand_type','image_text'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='menu_brand_type');
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'b0000001-0000-0000-0000-000000000005','theme','menu_brand_image','/themes/default/images/xcall_logo.svg'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='menu_brand_image');
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'b0000001-0000-0000-0000-000000000006','theme','logo_login','/themes/default/images/xcall_logo.svg'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='logo_login');
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'b0000001-0000-0000-0000-000000000007','theme','logo_header','/themes/default/images/xcall_logo.svg'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='logo_header');
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'b0000001-0000-0000-0000-000000000008','theme','favicon','/themes/default/images/xcall_favicon.svg'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='favicon');
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'b0000001-0000-0000-0000-000000000009','theme','footer','Powered by XCall PBX'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='footer');

UPDATE v_default_settings SET default_setting_value='/themes/default/images/xcall.css'
 WHERE default_setting_category='theme' AND default_setting_subcategory='custom_css';
UPDATE v_default_settings SET default_setting_value='XCall PBX'
 WHERE default_setting_category='theme' AND default_setting_subcategory='menu_brand_text';
UPDATE v_default_settings SET default_setting_value='image_text'
 WHERE default_setting_category='theme' AND default_setting_subcategory='menu_brand_type';
UPDATE v_default_settings SET default_setting_value='/themes/default/images/xcall_logo.svg'
 WHERE default_setting_category='theme' AND default_setting_subcategory='logo_login';
UPDATE v_default_settings SET default_setting_value='/themes/default/images/xcall_logo.svg'
 WHERE default_setting_category='theme' AND default_setting_subcategory='logo_header';
UPDATE v_default_settings SET default_setting_value='/themes/default/images/xcall_logo.svg'
 WHERE default_setting_category='theme' AND default_setting_subcategory='menu_brand_image';
UPDATE v_default_settings SET default_setting_value='/themes/default/images/xcall_logo.svg'
 WHERE default_setting_category='theme' AND default_setting_subcategory='menu_side_brand_image_contracted';
UPDATE v_default_settings SET default_setting_value='/themes/default/images/xcall_logo.svg'
 WHERE default_setting_category='theme' AND default_setting_subcategory='menu_side_brand_image_expanded';
UPDATE v_default_settings SET default_setting_value='Powered by XCall PBX'
 WHERE default_setting_category='theme' AND default_setting_subcategory='footer';
SQL

# add the "Admin Panel" entry below "Advanced" in the left sidebar
psql -U postgres -d fusionpbx \
    -f /var/www/fusionpbx/themes/default/images/admin_menu.sql \
    2>/dev/null \
    && echo "[xcall] added Admin Panel menu item" \
    || echo "[xcall] could not add Admin Panel menu item (access via /admin/)"

# apply the AI assistant schema (idempotent)
psql -U postgres -d fusionpbx -f /var/www/fusionpbx/ai-assistant/schema.sql 2>/dev/null \
    && echo "[xcall] AI assistant schema applied" \
    || echo "[xcall] AI assistant schema skipped"

wait "$STOCK_PID"
