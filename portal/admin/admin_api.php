<?php
/**
 * XCall — Admin Panel API.
 *
 * JSON API used by the admin pages:
 *   GET  admin_api.php?action=company_get
 *   POST admin_api.php?action=company_save          (JSON body)
 *   GET  admin_api.php?action=clients_list
 *   POST admin_api.php?action=client_save           (JSON body)
 *   POST admin_api.php?action=client_delete&client_uuid=<uuid>
 *   GET  admin_api.php?action=brand_preview         (returns branding vars for the portal header)
 */

require_once dirname(__DIR__) . "/ai-assistant/api_helpers.php";

$action = $_GET["action"] ?? "";
$domain_uuid = $_SESSION["domain_uuid"] ?? "00000000-0000-0000-0000-000000000000";

/**
 * Generate a RFC 4122 v4 UUID (used when inserting new default settings).
 */
function xcall_uuid_v4(): string {
    $data = random_bytes(16);
    $data[6] = chr((ord($data[6]) & 0x0f) | 0x40);
    $data[8] = chr((ord($data[8]) & 0x3f) | 0x80);
    return vsprintf("%s%s-%s-%s-%s-%s%s%s", str_split(bin2hex($data), 4));
}

/**
 * Upsert a value into FusionPBX's v_default_settings.
 *
 * A plain UPDATE silently no-ops when the setting row does not exist, which is
 * the reason company/branding changes never appeared. This updates the row if
 * it is present and inserts it as a new default when it is missing, so the
 * change reliably lands in the portal. Works on PostgreSQL (production) and the
 * local SQLite dev shim.
 *
 * @param mixed  $database  FusionPBX/emulated database object.
 * @param string $category  Setting category (e.g. 'theme').
 * @param string $subcategory Setting subcategory (e.g. 'menu_brand_text').
 * @param string $value     Value to store.
 */
function xcall_upsert_theme_setting($database, string $category, string $subcategory, string $value, string $description = ""): void {
    // 1) update an existing row (no-op if the row is absent)
    try {
        $database->execute(
            "update v_default_settings set default_setting_value = :v "
            . "where default_setting_category = :c and default_setting_subcategory = :s",
            ["v" => $value, "c" => $category, "s" => $subcategory]
        );

        // 2) insert a new default if the row does not exist yet
        $exists = $database->select(
            "select count(*) from v_default_settings "
            . "where default_setting_category = :c and default_setting_subcategory = :s",
            ["c" => $category, "s" => $subcategory],
            "var"
        );
        if (!$exists) {
            $database->execute(
                "insert into v_default_settings "
                . "(default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value) "
                . "values (:uuid, :c, :s, :v)",
                ["uuid" => xcall_uuid_v4(), "c" => $category, "s" => $subcategory, "v" => $value]
            );
        }
    } catch (Throwable $e) {
        // v_default_settings may be absent in minimal deployments — carry on
    }
}

/**
 * Push the XCall admin "System & Company" branding into the FusionPBX theme.
 * Mirrors the fields saved by company_save.
 */
function xcall_push_branding($database, array $fields): void {
    $sys   = trim($fields["system_name"] ?? "") ?: "XCall";
    $logo  = trim($fields["logo_path"] ?? "");
    $pri   = trim($fields["primary_color"] ?? "#6366f1");
    $acc   = trim($fields["accent_color"] ?? "#22d3ee");

    // system / product name
    xcall_upsert_theme_setting($database, "theme", "product_name", $sys);
    xcall_upsert_theme_setting($database, "theme", "menu_brand_text", $sys);
    xcall_upsert_theme_setting($database, "theme", "footer", "Powered by " . $sys);

    // logo across the portal (header menu + login page + favicon)
    if ($logo === "") {
        $logo = "/themes/default/images/xcall_logo.svg";
    }
    xcall_upsert_theme_setting($database, "theme", "menu_brand_image", $logo);
    xcall_upsert_theme_setting($database, "theme", "menu_side_brand_image_contracted", $logo);
    xcall_upsert_theme_setting($database, "theme", "menu_side_brand_image_expanded", $logo);
    xcall_upsert_theme_setting($database, "theme", "logo_login", $logo);
    xcall_upsert_theme_setting($database, "theme", "logo_header", $logo);
    xcall_upsert_theme_setting($database, "theme", "menu_brand_type", "image_text");

    // palette (primary -> links/menu, accent -> hovers/buttons)
    xcall_upsert_theme_setting($database, "theme", "menu_main_background_color", "#0f172a");
    xcall_upsert_theme_setting($database, "theme", "text_link_color", $pri);
    xcall_upsert_theme_setting($database, "theme", "text_link_color_hover", "#818cf8");
    xcall_upsert_theme_setting($database, "theme", "menu_main_text_color_hover", $acc);
    xcall_upsert_theme_setting($database, "theme", "menu_main_icon_color", $acc);
    xcall_upsert_theme_setting($database, "theme", "menu_sub_text_color_hover", $acc);
    xcall_upsert_theme_setting($database, "theme", "login_button_color", $acc);
    xcall_upsert_theme_setting($database, "theme", "login_button_color_hover", $pri);
}

switch ($action) {

    case "company_get": {
        $row = $database->select(
            "select * from v_xcall_company where domain_uuid = :domain_uuid limit 1",
            ["domain_uuid" => $domain_uuid],
            "row"
        );
        if (!$row) {
            $database->execute(
                "insert into v_xcall_company (domain_uuid) values (:domain_uuid)",
                ["domain_uuid" => $domain_uuid]
            );
            $row = $database->select(
                "select * from v_xcall_company where domain_uuid = :domain_uuid limit 1",
                ["domain_uuid" => $domain_uuid],
                "row"
            );
        }
        xcall_ok(["company" => $row]);
    }

    case "company_save": {
        $data = xcall_input_json();
        $fields = [
            "system_name" => trim($data["system_name"] ?? "") ?: "XCall",
            "tagline" => trim($data["tagline"] ?? ""),
            "logo_path" => trim($data["logo_path"] ?? ""),
            "primary_color" => trim($data["primary_color"] ?? "#6366f1"),
            "accent_color" => trim($data["accent_color"] ?? "#22d3ee"),
            "company_name" => trim($data["company_name"] ?? ""),
            "company_phone" => trim($data["company_phone"] ?? ""),
            "company_email" => trim($data["company_email"] ?? ""),
            "company_address" => trim($data["company_address"] ?? ""),
            "company_website" => trim($data["company_website"] ?? ""),
        ];
        $sets = [];
        $params = ["domain_uuid" => $domain_uuid];
        foreach ($fields as $col => $val) {
            $sets[] = "$col = :$col";
            $params[$col] = $val;
        }
        $sets[] = "company_updated = now()";
        $sql = "update v_xcall_company set " . implode(", ", $sets)
             . " where domain_uuid = :domain_uuid";
        $database->execute($sql, $params);
        // push the system name, logo and palette into FusionPBX branding
        // (v_default_settings). The upsert creates missing rows, so the portal
        // header / login / footer actually update — previously only an existing
        // row was updated, which silently no-oped and left the details stuck.
        xcall_push_branding($database, $fields);
        xcall_ok(["saved" => true]);
    }

    case "logo_upload": {
        // Accept a multipart/form-data upload ("file") and store it under the
        // web root so the portal can serve it. Returns the public URL path.
        if (empty($_FILES["file"]["tmp_name"])) {
            xcall_fail("no file uploaded");
        }
        $f = $_FILES["file"];
        if ($f["error"] !== UPLOAD_ERR_OK) {
            xcall_fail("upload error " . $f["error"]);
        }
        if ($f["size"] > (2 * 1024 * 1024)) {
            xcall_fail("logo too large (max 2 MB)");
        }

        // sanitise + whitelist the extension
        $original = basename(preg_replace('/[^A-Za-z0-9._-]/', '', $f["name"]));
        $ext = strtolower(pathinfo($original, PATHINFO_EXTENSION));
        $allowed = ["svg", "png", "jpg", "jpeg", "gif", "webp", "ico"];
        if (!in_array($ext, $allowed, true)) {
            xcall_fail("unsupported file type (allowed: " . implode(", ", $allowed) . ")");
        }

        // light content sniff (skip on SVG, which is text/xml)
        if ($ext !== "svg" && function_exists("finfo_open")) {
            $fi = finfo_open(FILEINFO_MIME_TYPE);
            $mime = finfo_file($fi, $f["tmp_name"]);
            finfo_close($fi);
            $gfx = ["image/png" => "png", "image/jpeg" => "jpg", "image/gif" => "gif", "image/webp" => "webp"]; 
            if (isset($gfx[$mime])) {
                // normalise the extension to the real mime (defeats fake .png uploads)
                $ext = $gfx[$mime];
            }
        }

        $web_root = dirname(__DIR__);
        $dir = $web_root . "/resources/xcall_brand";
        if (!is_dir($dir)) {
            mkdir($dir, 0775, true);
        }
        $fname = "logo_" . date("Ymd_His") . "_" . substr(bin2hex(random_bytes(4)), 0, 8) . "." . $ext;
        $dest = $dir . "/" . $fname;
        if (!@move_uploaded_file($f["tmp_name"], $dest)) {
            xcall_fail("could not save the uploaded logo");
        }
        @chmod($dest, 0664);

        $path = "/resources/xcall_brand/" . $fname;
        xcall_ok(["path" => $path, "url" => $path]);
    }

    case "softphone_save": {
        $data = xcall_input_json();
        $fields = [
            "softphone_theme" => trim($data["softphone_theme"] ?? "dark"),
            "softphone_ringtone" => trim($data["softphone_ringtone"] ?? "default"),
            "softphone_hold_music" => trim($data["softphone_hold_music"] ?? "local_stream://moh"),
            "softphone_auto_answer" => !empty($data["softphone_auto_answer"]) ? "true" : "false",
            "softphone_enabled" => !empty($data["softphone_enabled"]) ? "true" : "false",
        ];
        if (isset($data["assistant_default_uuid"])) {
            $fields["assistant_default_uuid"] = $data["assistant_default_uuid"] === ""
                ? null : trim($data["assistant_default_uuid"]);
        }
        $sets = [];
        $params = ["domain_uuid" => $domain_uuid];
        foreach ($fields as $col => $val) {
            $sets[] = "$col = :$col";
            $params[$col] = $val;
        }
        $sets[] = "company_updated = now()";
        $database->execute(
            "update v_xcall_company set " . implode(", ", $sets)
            . " where domain_uuid = :domain_uuid",
            $params
        );
        xcall_ok(["saved" => true]);
    }

    case "clients_list": {
        $rows = $database->select(
            "select * from v_xcall_clients where domain_uuid = :domain_uuid "
            . "order by client_name asc",
            ["domain_uuid" => $domain_uuid],
            "all"
        );
        xcall_ok(["clients" => $rows ?: []]);
    }

    case "client_save": {
        $data = xcall_input_json();
        $uuid = trim($data["client_uuid"] ?? "");
        $name = trim($data["client_name"] ?? "");
        if ($name === "") {
            xcall_fail("client_name is required");
        }
        $fields = [
            "client_name" => $name,
            "client_phone" => trim($data["client_phone"] ?? ""),
            "client_email" => trim($data["client_email"] ?? ""),
            "client_company" => trim($data["client_company"] ?? ""),
            "client_notes" => trim($data["client_notes"] ?? ""),
            "client_status" => in_array(trim($data["client_status"] ?? "active"), ["active", "inactive", "lead"], true)
                ? trim($data["client_status"]) : "active",
        ];
        if ($uuid) {
            $sets = [];
            $params = ["uuid" => $uuid, "domain_uuid" => $domain_uuid];
            foreach ($fields as $col => $val) {
                $sets[] = "$col = :$col";
                $params[$col] = $val;
            }
            $sets[] = "client_updated = now()";
            $database->execute(
                "update v_xcall_clients set " . implode(", ", $sets)
                . " where client_uuid = :uuid and domain_uuid = :domain_uuid",
                $params
            );
        } else {
            $params = $fields;
            $params["domain_uuid"] = $domain_uuid;
            $cols = array_keys($params);
            $database->execute(
                "insert into v_xcall_clients (" . implode(", ", $cols) . ") "
                . "values (:" . implode(", :", $cols) . ")",
                $params
            );
        }
        xcall_ok(["saved" => true]);
    }

    case "client_delete": {
        $uuid = $_GET["client_uuid"] ?? "";
        if (!$uuid) {
            xcall_fail("client_uuid required");
        }
        $database->execute(
            "delete from v_xcall_clients where client_uuid = :uuid and domain_uuid = :domain_uuid",
            ["uuid" => $uuid, "domain_uuid" => $domain_uuid]
        );
        xcall_ok(["deleted" => true]);
    }

    case "brand_preview": {
        $row = $database->select(
            "select * from v_xcall_company where domain_uuid = :domain_uuid limit 1",
            ["domain_uuid" => $domain_uuid],
            "row"
        );
        xcall_ok([
            "brand" => $row ?: [
                "system_name" => "XCall",
                "tagline" => "Cloud PBX",
                "logo_path" => "/themes/default/images/xcall_logo.svg",
                "primary_color" => "#6366f1",
                "accent_color" => "#22d3ee",
            ],
        ]);
    }

    default:
        xcall_fail("unknown action: $action", 404);
}
