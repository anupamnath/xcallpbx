-- XCall PBX — add an "Admin Panel" menu item to the FusionPBX left sidebar,
-- directly below the "Advanced" group.
--
-- FusionPBX stores its menu in the database (v_menus / v_menu_items /
-- v_menu_languages / v_menu_item_groups). This script:
--   1. ensures the default menu exists,
--   2. locates the "Advanced" parent group (by its well-known anchor uuid and,
--      as a fallback, by title),
--   3. makes room for (and inserts) a new top-level "Admin Panel" item that
--      links to /admin/,
--   4. adds its display title in v_menu_languages,
--   5. grants it to the superadmin group.
--
-- It is idempotent and safe to run repeatedly. Run as the fusionpbx database
-- user, e.g.:
--
--   psql fusionpbx -f admin_menu.sql
--
-- If the menu tables are absent (e.g. a trimmed DB) it is a no-op.

DO $$
DECLARE
    v_menu_uuid       uuid := 'b4750c3f-2a86-b00d-b7d0-345c14eca286'; -- default menu
    v_anchor_uuid     uuid := '594d99c5-6128-9c88-ca35-4b33392cec0f'; -- "Advanced" group
    v_advanced_uuid   uuid;
    v_advanced_order  integer;
    v_group_uuid      uuid;
    v_group_name      text;
    v_item_uuid       uuid := 'a0000002-0000-0000-0000-000000000001';
    v_lang_uuid       uuid := 'a0000002-0000-0000-0000-000000000002';
    v_grouprow_uuid   uuid := 'a0000002-0000-0000-0000-000000000003';
BEGIN
    -- Skip when the menu schema is not present (e.g. non-Postgres dev shim)
    IF to_regclass('v_menu_items') IS NULL THEN
        RAISE NOTICE 'Admin Panel menu skipped: v_menu_items table not found';
        RETURN;
    END IF;

    -- Already installed? Be idempotent (do not shift menu order again).
    IF EXISTS (SELECT 1 FROM v_menu_items WHERE menu_item_uuid = v_item_uuid) THEN
        RAISE NOTICE 'Admin Panel menu item already present — skipping';
        RETURN;
    END IF;

    -- ensure the default menu row exists
    INSERT INTO v_menus (menu_uuid, menu_name, menu_language, menu_description)
    VALUES (v_menu_uuid, 'default', 'en-us', 'Default Menu')
    ON CONFLICT (menu_uuid) DO NOTHING;

    -- Locate the "Advanced" parent (top-level, parent_uuid IS NULL)
    SELECT i.menu_item_uuid, i.menu_item_order
      INTO v_advanced_uuid, v_advanced_order
      FROM v_menu_items i
     WHERE i.menu_uuid = v_menu_uuid
       AND i.menu_item_parent_uuid IS NULL
       AND (i.uuid = v_anchor_uuid
            OR lower(i.menu_item_title) = 'advanced'
            OR EXISTS (SELECT 1 FROM v_menu_languages l
                        WHERE l.menu_item_uuid = i.menu_item_uuid
                          AND lower(l.menu_item_title) = 'advanced'))
     ORDER BY i.menu_item_order
     LIMIT 1;

    -- If Advanced could not be found, append after the last top-level item
    IF v_advanced_uuid IS NULL THEN
        SELECT COALESCE(MAX(menu_item_order), 0) INTO v_advanced_order
          FROM v_menu_items WHERE menu_uuid = v_menu_uuid AND menu_item_parent_uuid IS NULL;
    END IF;

    -- make room for the new item directly below Advanced
    UPDATE v_menu_items SET menu_item_order = menu_item_order + 1
     WHERE menu_uuid = v_menu_uuid
       AND menu_item_parent_uuid IS NULL
       AND menu_item_order > COALESCE(v_advanced_order, 0);

    -- insert the top-level "Admin Panel" item
    INSERT INTO v_menu_items
        (menu_item_uuid, uuid, menu_uuid, menu_item_parent_uuid, menu_item_title,
         menu_item_link, menu_item_category, menu_item_icon, menu_item_icon_color,
         menu_item_order, menu_item_protected, menu_item_description)
    VALUES
        (v_item_uuid, v_item_uuid, v_menu_uuid, NULL, 'Admin_panel',
         '/admin/', 'internal', 'fa-solid fa-sliders', '#22d3ee',
         COALESCE(v_advanced_order, 0) + 1, 'false', 'XCall PBX admin panel')
    ON CONFLICT (menu_item_uuid) DO NOTHING;

    -- display title (English)
    INSERT INTO v_menu_languages (menu_language_uuid, menu_item_uuid, menu_uuid, menu_language, menu_item_title)
    VALUES (v_lang_uuid, v_item_uuid, v_menu_uuid, 'en-us', 'Admin Panel')
    ON CONFLICT (menu_language_uuid) DO NOTHING;

    -- grant to the superadmin group
    SELECT group_uuid, group_name INTO v_group_uuid, v_group_name
      FROM v_groups WHERE lower(group_name) = 'superadmin' LIMIT 1;
    IF v_group_uuid IS NOT NULL THEN
        INSERT INTO v_menu_item_groups (menu_item_group_uuid, menu_uuid, menu_item_uuid, group_name, group_uuid)
        VALUES (v_grouprow_uuid, v_menu_uuid, v_item_uuid, v_group_name, v_group_uuid)
        ON CONFLICT (menu_item_group_uuid) DO NOTHING;
    END IF;

    RAISE NOTICE 'Admin Panel menu item installed through /admin/ (order %)', COALESCE(v_advanced_order, 0) + 1;
END $$;
