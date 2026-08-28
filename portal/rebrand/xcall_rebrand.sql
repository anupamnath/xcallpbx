-- XCall PBX branding — apply to a FusionPBX database.
--
-- Sets the brand-related theme/default settings for the default domain so the
-- portal renders with the "XCall PBX" name, logo and colors. Run as the
-- fusionpbx database user:
--
--   psql fusionpbx -f xcall_rebrand.sql
--
-- These are "default settings" so they apply to every domain. Change the
-- values to match your deployment (logo paths are relative to the web root).
--
-- Each key is UPDATEd when the row exists and INSERTed as a new default when
-- it does not — so the admin panel / installer branding always sticks. This is
-- the difference from a plain UPDATE, which silently no-ops on a missing row.

-- ------------------------------------------------------------------ #
-- product / system name  ("XCall PBX")
-- ------------------------------------------------------------------ #
-- Each key is UPDATEd when the row exists and INSERTed when it does not, so
-- the branding always sticks (a plain UPDATE silently no-ops otherwise).
UPDATE v_default_settings SET default_setting_value = 'XCall PBX'
 WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'menu_brand_text';
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'a0000001-0000-0000-0000-000000000001', 'theme', 'menu_brand_text', 'XCall PBX'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='menu_brand_text');

UPDATE v_default_settings SET default_setting_value = 'XCall PBX'
 WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'product_name';
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'a0000001-0000-0000-0000-000000000002', 'theme', 'product_name', 'XCall PBX'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='product_name');

-- brand type: show the logo + text in the top menu (image_text)
UPDATE v_default_settings SET default_setting_value = 'image_text'
 WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'menu_brand_type';
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'a0000001-0000-0000-0000-000000000004', 'theme', 'menu_brand_type', 'image_text'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='menu_brand_type');

-- logo in the top menu bar (used when menu_brand_type = image_text)
UPDATE v_default_settings SET default_setting_value = '/themes/default/images/xcall_logo.svg'
 WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'menu_brand_image';
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'a0000001-0000-0000-0000-000000000005', 'theme', 'menu_brand_image', '/themes/default/images/xcall_logo.svg'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='menu_brand_image');

-- login page logo (svg works fine in modern browsers)
UPDATE v_default_settings SET default_setting_value = '/themes/default/images/xcall_logo.svg'
 WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'logo_login';
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'a0000001-0000-0000-0000-000000000006', 'theme', 'logo_login', '/themes/default/images/xcall_logo.svg'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='logo_login');

UPDATE v_default_settings SET default_setting_value = '/themes/default/images/xcall_logo.svg'
 WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'logo_header';
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'a0000001-0000-0000-0000-000000000007', 'theme', 'logo_header', '/themes/default/images/xcall_logo.svg'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='logo_header');

-- browser favicon
UPDATE v_default_settings SET default_setting_value = '/themes/default/images/xcall_favicon.svg'
 WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'favicon';
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'a0000001-0000-0000-0000-000000000008', 'theme', 'favicon', '/themes/default/images/xcall_favicon.svg'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='favicon');

-- logo in the left side menu (contracted + expanded)
UPDATE v_default_settings SET default_setting_value = '/themes/default/images/xcall_logo.svg'
 WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'menu_side_brand_image_contracted';
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'a0000001-0000-0000-0000-000000000010', 'theme', 'menu_side_brand_image_contracted', '/themes/default/images/xcall_logo.svg'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='menu_side_brand_image_contracted');

UPDATE v_default_settings SET default_setting_value = '/themes/default/images/xcall_logo.svg'
 WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'menu_side_brand_image_expanded';
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'a0000001-0000-0000-0000-000000000011', 'theme', 'menu_side_brand_image_expanded', '/themes/default/images/xcall_logo.svg'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='menu_side_brand_image_expanded');

-- ------------------------------------------------------------------ #
-- footer
-- ------------------------------------------------------------------ #
UPDATE v_default_settings SET default_setting_value = 'Powered by XCall PBX'
 WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'footer';
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'a0000001-0000-0000-0000-000000000003', 'theme', 'footer', 'Powered by XCall PBX'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='theme' AND default_setting_subcategory='footer');

-- ------------------------------------------------------------------ #
-- brand palette (XCall cyan -> indigo)
-- ------------------------------------------------------------------ #
UPDATE v_default_settings SET default_setting_value = '#0f172a'      WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'menu_main_background_color';
UPDATE v_default_settings SET default_setting_value = '#1e293b'      WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'menu_sub_background_color';
UPDATE v_default_settings SET default_setting_value = '#22d3ee'      WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'menu_main_text_color_hover';
UPDATE v_default_settings SET default_setting_value = '#22d3ee'      WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'menu_main_icon_color';
UPDATE v_default_settings SET default_setting_value = '#6366f1'      WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'text_link_color';
UPDATE v_default_settings SET default_setting_value = '#818cf8'      WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'text_link_color_hover';
UPDATE v_default_settings SET default_setting_value = '#22d3ee'      WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'menu_sub_text_color_hover';
UPDATE v_default_settings SET default_setting_value = '#e2e8f0'      WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'menu_main_text_color';

-- login page accent
UPDATE v_default_settings SET default_setting_value = '#22d3ee'      WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'login_button_color';
UPDATE v_default_settings SET default_setting_value = '#6366f1'      WHERE default_setting_category = 'theme' AND default_setting_subcategory = 'login_button_color_hover';

-- ------------------------------------------------------------------ #
-- Register the XCall theme as an available template (optional).
UPDATE v_default_settings SET default_setting_value = 'default'
 WHERE default_setting_category = 'domain' AND default_setting_subcategory = 'template';
INSERT INTO v_default_settings (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
SELECT 'a0000001-0000-0000-0000-000000000009', 'domain', 'template', 'default'
WHERE NOT EXISTS (SELECT 1 FROM v_default_settings WHERE default_setting_category='domain' AND default_setting_subcategory='template');
