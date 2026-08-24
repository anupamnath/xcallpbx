<?php
/**
 * XCall — local dev router for PHP's built-in server.
 *
 *   php -S 127.0.0.1:8080 -t portal local/dev-router.php
 *
 * Serves the XCall landing page for "/" (and FusionPBX dashboard paths),
 * and lets the built-in server handle everything else (the AI Assistant
 * pages + web softphone live under portal/).
 */

$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) ?? '/';

// landing page for the portal root + FusionPBX dashboard links
if ($path === '/' || $path === '' || strpos($path, '/core/') === 0) {
    require __DIR__ . '/landing.php';
    return true;
}

// let the built-in server serve static files + PHP pages
return false;
