<?php
/**
 * XCall — web softphone configuration endpoint.
 *
 * Returns the SIP/WebRTC settings the browser softphone needs, populated from
 * the logged-in FusionPBX user's session and domain settings. This keeps
 * credentials out of the page and tied to the portal login.
 *
 * Place this file in the FusionPBX web root (e.g. webphone/config.php) and
 * access it as: /webphone/config.php
 *
 * Responses:
 *   - 401 + {error} if no authenticated session
 *   - 200 + {ws, domain, username, password, displayName, ...}
 */

require_once __DIR__ . "/../resources/require.php";

header("Content-Type: application/json");

// require an authenticated portal session
if (empty($_SESSION['username'])) {
    http_response_code(401);
    echo json_encode(["error" => "not authenticated"]);
    exit;
}

$domain_uuid = $_SESSION['domain_uuid'] ?? '';
$username    = $_SESSION['username'] ?? '';
$extension   = $_SESSION['extension'] ?? $username;

$settings = new settings(['database' => $database, 'domain_uuid' => $domain_uuid]);

// WebSocket endpoint the browser will dial into.
// These come from the domain settings (verto) or from this file's constants.
$ws_server      = $settings->get('domain', 'verto_ws_address', '');
$ws_port        = $settings->get('domain', 'verto_ws_port', '8081');
$ws_secure_port = $settings->get('domain', 'verto_wss_port', '8082');
$domain_name    = $settings->get('domain', 'name', $_SESSION['domain_name'] ?? '');

// prefer secure, fall back to plain ws, else derive from the page origin
if (empty($ws_server)) {
    $ws_server = $_SERVER['HTTP_HOST'] ?? '';
}

$ws_url = 'ws://' . $ws_server . ':' . $ws_port;
if (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') {
    // Same-origin TLS path through the portal reverse proxy
    // (nginx /verto -> FreeSWITCH SIP-over-WebSocket). This avoids the browser
    // rejecting FreeSWITCH's self-signed WebSocket certificate.
    $ws_url = 'wss://' . $ws_server . '/verto';
}

$user_row = null;
$user_password = '';
if (!empty($domain_uuid) && !empty($username)) {
    $sql = "select u.user_uuid, u.username, u.extension, u.user_password, " .
           "u.user_caller_id_name, u.user_caller_id_number, u.user_enabled " .
           "from v_users u " .
           "where u.domain_uuid = :domain_uuid and u.username = :username ";
    $parameters['domain_uuid'] = $domain_uuid;
    $parameters['username']    = $username;
    $user_row = $database->select($sql, $parameters, 'row');
    if (!empty($user_row['user_password'])) {
        $user_password = $user_row['user_password'];
    }
}

echo json_encode([
    'domain'     => $domain_name ?: ($_SERVER['HTTP_HOST'] ?? ''),
    'extension'  => $extension ?: ($user_row['extension'] ?? ''),
    'username'   => $username,
    'password'   => $user_password,
    'displayName'=> $user_row['user_caller_id_name'] ?? ($_SESSION['user_caller_id_name'] ?? ''),
    'callerId'   => $user_row['user_caller_id_number'] ?? ($_SESSION['user_caller_id_number'] ?? ''),
    'ws'         => $ws_url,
    'scheme'     => (strpos($ws_url, 'wss://') === 0) ? 'wss' : 'ws',
    'wsPort'     => (int)$ws_port,
    'verto'      => (bool)$settings->get('domain', 'web_rtc_enabled', false),
], JSON_PRETTY_PRINT);
