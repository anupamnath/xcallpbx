-- XCall branding — apply to a FusionPBX database.
--
-- Sets the brand-related theme/default settings for the default domain so the
-- portal renders with the XCall name, logo and colors. Run as the fusionpbx
-- database user:
--
--   psql fusionpbx -f xcall_rebrand.sql
--
-- These are "default settings" so they apply to every domain. Change the
-- values to match your deployment (logo paths are relative to the web root).

-- ------------------------------------------------------------------ #
-- product / system name
-- ------------------------------------------------------------------ #
UPDATE v_default_settings
   SET default_setting_value = 'XCall'
 WHERE default_setting_category = 'theme'
   AND default_setting_subcategory = 'menu_brand_text';

UPDATE v_default_settings
   SET default_setting_value = 'XCall'
 WHERE default_setting_category = 'theme'
   AND default_setting_subcategory = 'product_name';

-- brand type: text logo in the menu
UPDATE v_default_settings
   SET default_setting_value = 'text'
 WHERE default_setting_category = 'theme'
   AND default_setting_subcategory = 'menu_brand_type';

-- login page logo (svg works fine in modern browsers)
UPDATE v_default_settings
   SET default_setting_value = '/themes/default/images/logo_login.png'
 WHERE default_setting_category = 'theme'
   AND default_setting_subcategory = 'logo_login';

UPDATE v_default_settings
   SET default_setting_value = '/themes/default/images/logo_header.png'
 WHERE default_setting_category = 'theme'
   AND default_setting_subcategory = 'logo_header';

UPDATE v_default_settings
   SET default_setting_value = '/themes/default/images/favicon.ico'
 WHERE default_setting_category = 'theme'
   AND default_setting_subcategory = 'favicon';

-- ------------------------------------------------------------------ #
-- footer
-- ------------------------------------------------------------------ #
UPDATE v_default_settings
   SET default_setting_value = 'Powered by XCall'
 WHERE default_setting_category = 'theme'
   AND default_setting_subcategory = 'footer';

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
-- insert any keys that don't exist yet (safety net)
-- ------------------------------------------------------------------ #
-- (Subcategories vary between versions; the UPDATEs above are safe no-ops
--  when a key is absent. For a fresh install, the XCall theme config file
--  below defines all keys with XCall values.)

-- Register the XCall theme as an available template (optional).
UPDATE v_default_settings
   SET default_setting_value = 'default'
 WHERE default_setting_category = 'domain'
   AND default_setting_subcategory = 'template';
