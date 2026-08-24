<?php
/**
 * XCall — AI Assistant API.
 *
 * JSON API used by:
 *   - the portal UI  (list / get / save / delete)
 *   - the AI agent   (action=agent_config, authenticated with a shared secret)
 *
 * Endpoints:
 *   GET  assistant_api.php?action=list
 *   GET  assistant_api.php?action=get&assistant_uuid=<uuid>
 *   POST assistant_api.php?action=save                        (JSON body)
 *   POST assistant_api.php?action=delete&assistant_uuid=<uuid>
 *   GET  assistant_api.php?action=agent_config&key=<secret>   (agent only)
 *   GET  assistant_api.php?action=default_config              (agent fallback)
 *
 * Note: the xcall_* helpers are loaded by api_helpers.php into the global
 * namespace, so no `use function` import is needed (and it would emit a
 * PHP 8.4 warning that pollutes the JSON response).
 */

require_once __DIR__ . "/api_helpers.php";

$action = $_GET["action"] ?? "";
$domain_uuid = $_SESSION["domain_uuid"] ?? "00000000-0000-0000-0000-000000000000";

switch ($action) {

    case "list": {
        $sql = "select assistant_uuid, assistant_name, assistant_provider, assistant_model, "
             . "assistant_enabled, assistant_created, assistant_updated "
             . "from v_xcall_assistants "
             . "where domain_uuid = :domain_uuid order by assistant_updated desc";
        $rows = $database->select($sql, ["domain_uuid" => $domain_uuid], "all");
        xcall_ok(["assistants" => $rows ?: []]);
    }

    case "get": {
        $uuid = $_GET["assistant_uuid"] ?? "";
        if (!$uuid) {
            xcall_fail("assistant_uuid required");
        }
        $sql = "select * from v_xcall_assistants where assistant_uuid = :uuid and domain_uuid = :domain_uuid";
        $row = $database->select($sql, ["uuid" => $uuid, "domain_uuid" => $domain_uuid], "row");
        if (!$row) {
            xcall_fail("assistant not found", 404);
        }
        $row["assistant_api_key_enc"] = xcall_decrypt_secret($row["assistant_api_key_enc"] ?? "");
        xcall_ok(["assistant" => $row]);
    }

    case "save": {
        $data = xcall_input_json();
        $uuid = $data["assistant_uuid"] ?? "";
        $name = trim($data["assistant_name"] ?? "");
        if ($name === "") {
            xcall_fail("assistant_name is required");
        }

        $fields = [
            "assistant_name" => $name,
            "assistant_greeting" => $data["assistant_greeting"] ?? "",
            "assistant_instructions" => $data["assistant_instructions"] ?? "",
            "assistant_provider" => $data["assistant_provider"] ?? "openai",
            "assistant_model" => $data["assistant_model"] ?? "",
            "assistant_api_base_url" => $data["assistant_api_base_url"] ?? "",
            "assistant_temperature" => floatval($data["assistant_temperature"] ?? 0.7),
            "assistant_max_tokens" => intval($data["assistant_max_tokens"] ?? 1024),
            "assistant_voice" => $data["assistant_voice"] ?? "default",
            "assistant_language" => $data["assistant_language"] ?? "en",
            "assistant_stt_engine" => $data["assistant_stt_engine"] ?? "whisper",
            "assistant_tts_engine" => $data["assistant_tts_engine"] ?? "piper",
            "assistant_handoff_extension" => $data["assistant_handoff_extension"] ?? "7000",
            "assistant_handoff_message" => $data["assistant_handoff_message"] ?? "",
            "assistant_max_call_seconds" => intval($data["assistant_max_call_seconds"] ?? 900),
            "assistant_silence_retries" => intval($data["assistant_silence_retries"] ?? 2),
            "assistant_enabled" => !empty($data["assistant_enabled"]) ? "true" : "false",
        ];

        $api_key = trim($data["assistant_api_key"] ?? "");

        if ($uuid) {
            $sets = [];
            $params = [];
            foreach ($fields as $col => $val) {
                $sets[] = "$col = :$col";
                $params[$col] = $val;
            }
            if ($api_key !== "") {
                $sets[] = "assistant_api_key_enc = :key_enc";
                $params["key_enc"] = xcall_encrypt_secret($api_key);
            }
            $sets[] = "assistant_updated = now()";
            $params["uuid"] = $uuid;
            $params["domain_uuid"] = $domain_uuid;
            $sql = "update v_xcall_assistants set " . implode(", ", $sets)
                 . " where assistant_uuid = :uuid and domain_uuid = :domain_uuid";
            $database->execute($sql, $params);
        } else {
            $params = $fields;
            $params["domain_uuid"] = $domain_uuid;
            if ($api_key !== "") {
                $params["assistant_api_key_enc"] = xcall_encrypt_secret($api_key);
            }
            $cols = array_keys($params);
            $sql = "insert into v_xcall_assistants (" . implode(", ", $cols) . ") "
                 . "values (:" . implode(", :", $cols) . ")";
            $database->execute($sql, $params);
        }
        xcall_ok(["saved" => true]);
    }

    case "delete": {
        $uuid = $_GET["assistant_uuid"] ?? "";
        if (!$uuid) {
            xcall_fail("assistant_uuid required");
        }
        $sql = "delete from v_xcall_assistants where assistant_uuid = :uuid and domain_uuid = :domain_uuid";
        $database->execute($sql, ["uuid" => $uuid, "domain_uuid" => $domain_uuid]);
        xcall_ok(["deleted" => true]);
    }

    case "local_models": {
        // Probe well-known local AI endpoints on the PBX host and list models.
        // This lets the admin pick a local model (Ollama, LM Studio, vLLM,
        // llama.cpp, LocalAI) without typing the base URL / model name.
        $servers = [];
        $probes = [
            // provider => [name, [candidate base urls], models path]
            "ollama"    => ["Ollama",    ["http://127.0.0.1:11434"],                  "api/tags",          true],
            "lmstudio"  => ["LM Studio", ["http://127.0.0.1:1234/v1"],                "models",            false],
            "vllm"      => ["vLLM",      ["http://127.0.0.1:8000/v1"],                "models",            false],
            "llamacpp"  => ["llama.cpp", ["http://127.0.0.1:8080/v1"],                "models",            false],
            "localai"   => ["LocalAI",   ["http://127.0.0.1:8080/v1", "http://127.0.0.1:8080/v1"], "models", false],
        ];
        foreach ($probes as $provider => [$name, $urls, $path, $is_ollama]) {
            foreach ($urls as $base_url) {
                $endpoint = rtrim($base_url, "/") . "/" . $path;
                $ctx = stream_context_create([
                    "http" => [
                        "timeout" => 1,
                        "ignore_errors" => true,
                        "header" => "Accept: application/json\r\n",
                    ],
                ]);
                $resp = @file_get_contents($endpoint, false, $ctx);
                if ($resp === false) {
                    continue;
                }
                $data = @json_decode($resp, true);
                if (!is_array($data)) {
                    continue;
                }
                $models = [];
                if ($is_ollama && isset($data["models"]) && is_array($data["models"])) {
                    foreach ($data["models"] as $m) {
                        $models[] = $m["name"] ?? $m["model"] ?? "";
                    }
                } elseif (isset($data["data"]) && is_array($data["data"])) {
                    foreach ($data["data"] as $m) {
                        $models[] = $m["id"] ?? $m["name"] ?? "";
                    }
                }
                $models = array_values(array_filter(array_map("trim", $models)));
                $servers[] = [
                    "provider" => $provider,
                    "name" => $name,
                    "base_url" => $base_url,
                    "models" => $models ?: [],
                ];
                break; // only the first reachable URL per provider
            }
        }
        xcall_ok(["servers" => $servers]);
    }

    // ------------------------------------------------------------------ #
    // AI agent endpoints (authenticated with the shared secret)
    // ------------------------------------------------------------------ #
    case "agent_config": {
        $key = $_GET["key"] ?? "";
        $secret = $database->select(
            "select setting_value from v_xcall_settings where setting_name = 'agent_shared_secret'",
            [],
            "var"
        );
        if (!$key || !$secret || !hash_equals($secret, $key)) {
            xcall_fail("unauthorized", 401);
        }
        $assistant_uuid = $_GET["assistant_uuid"] ?? "";
        if ($assistant_uuid) {
            $row = $database->select(
                "select * from v_xcall_assistants where assistant_uuid = :uuid",
                ["uuid" => $assistant_uuid],
                "row"
            );
        } else {
            $row = $database->select(
                "select * from v_xcall_assistants where domain_uuid = :domain_uuid "
                . "and assistant_enabled = true order by assistant_updated desc limit 1",
                ["domain_uuid" => $domain_uuid],
                "row"
            );
        }
        if (!$row) {
            xcall_fail("no active assistant configured", 404);
        }
        // the agent is a trusted server component; it needs the real key
        $row["assistant_api_key_enc"] = xcall_decrypt_secret($row["assistant_api_key_enc"] ?? "");
        xcall_ok(["assistant" => $row]);
    }

    case "default_config": {
        // static default so the agent can run before any assistant is saved
        xcall_ok(["assistant" => [
            "assistant_name" => "Default XCall Assistant",
            "assistant_greeting" => "Hello, thank you for calling. How can I help you today?",
            "assistant_instructions" => "You are a helpful and professional customer support agent. "
                . "Be concise. If you cannot resolve the issue, transfer the caller to a specialist.",
            "assistant_provider" => "openai",
            "assistant_model" => "gpt-4o-mini",
            "assistant_api_key_enc" => "",
            "assistant_api_base_url" => "",
            "assistant_temperature" => 0.7,
            "assistant_max_tokens" => 1024,
            "assistant_voice" => "default",
            "assistant_language" => "en",
            "assistant_stt_engine" => "stub",
            "assistant_tts_engine" => "stub",
            "assistant_handoff_extension" => "7000",
            "assistant_handoff_message" => "Please hold the line, I will connect you to a specialist.",
            "assistant_max_call_seconds" => 900,
            "assistant_silence_retries" => 2,
            "assistant_enabled" => true,
        ]]);
    }

    default:
        xcall_fail("unknown action: $action", 404);
}
