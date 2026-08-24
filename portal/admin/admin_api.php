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
        // also push the system name into FusionPBX branding (v_default_settings)
        if (!empty($fields["system_name"])) {
            try {
                $database->execute(
                    "update v_default_settings set default_setting_value = :v "
                    . "where default_setting_category = 'theme' "
                    . "and default_setting_subcategory in ('menu_brand_text', 'product_name')",
                    ["v" => $fields["system_name"]]
                );
                $database->execute(
                    "update v_default_settings set default_setting_value = :v "
                    . "where default_setting_category = 'theme' "
                    . "and default_setting_subcategory = 'footer'",
                    ["v" => "Powered by " . $fields["system_name"]]
                );
            } catch (Throwable $e) {
                // v_default_settings may not exist in the local SQLite demo shim
            }
        }
        xcall_ok(["saved" => true]);
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
