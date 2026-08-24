<?php
/**
 * XCall — shared helpers for the AI Assistant API.
 *
 * Provides JSON helpers and AES-256-GCM encryption for API keys.
 * The encryption key lives in resources/xcall_secrets.php (chmod 600).
 */

require_once dirname(__DIR__) . "/resources/require.php";

function xcall_fail(string $message, int $status = 400): void {
    http_response_code($status);
    echo json_encode(["error" => $message]);
    exit;
}

function xcall_ok(array $data = []): void {
    echo json_encode($data);
    exit;
}

function xcall_input_json(): array {
    $raw = file_get_contents("php://input");
    $data = json_decode($raw ?: "{}", true);
    if (!is_array($data)) {
        xcall_fail("invalid JSON body");
    }
    return $data;
}

function xcall_secret_config_path(): string {
    return dirname(__DIR__) . "/resources/xcall_secrets.php";
}

function xcall_get_encryption_key(): string {
    static $key = null;
    if ($key !== null) {
        return $key;
    }
    $path = xcall_secret_config_path();
    if (!is_file($path)) {
        // generate a random key on first use (installer should pre-create it)
        $key = bin2hex(random_bytes(32));
        file_put_contents($path, "<?php\n\$xcall_secret_key = '" . $key . "';\n");
        @chmod($path, 0600);
    } else {
        require $path;
        $key = $xcall_secret_key ?? "";
    }
    if (strlen($key) < 32) {
        xcall_fail("XCall encryption key missing or too short", 500);
    }
    return $key;
}

function xcall_encrypt_secret(string $plain): string {
    $key = xcall_get_encryption_key();
    $iv = random_bytes(12);
    $tag = "";
    $cipher = openssl_encrypt($plain, "aes-256-gcm", $key, OPENSSL_RAW_DATA, $iv, $tag);
    if ($cipher === false) {
        xcall_fail("encryption failed", 500);
    }
    return base64_encode($iv . $tag . $cipher);
}

function xcall_decrypt_secret(string $payload): string {
    $key = xcall_get_encryption_key();
    $raw = base64_decode($payload);
    if (strlen($raw) < 28) {
        return "";
    }
    $iv = substr($raw, 0, 12);
    $tag = substr($raw, 12, 16);
    $cipher = substr($raw, 28);
    $plain = openssl_decrypt($cipher, "aes-256-gcm", $key, OPENSSL_RAW_DATA, $iv, $tag);
    return $plain === false ? "" : $plain;
}
