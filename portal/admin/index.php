<?php
/**
 * XCall — Admin Panel dashboard.
 * Hub linking to system/company, clients, softphone, and AI assistant.
 */

require_once dirname(__DIR__, 2) . "/resources/require.php";
require_once dirname(__DIR__) . "/ai-assistant/api_helpers.php";

if (empty($_SESSION["username"])) {
    header("Location: " . PROJECT_PATH . "/login.php");
    exit;
}

$domain_uuid = $_SESSION["domain_uuid"] ?? "00000000-0000-0000-0000-000000000000";
// the v_xcall_* tables are created by the installer; guard against a missing
// schema so the panel shows a setup hint instead of a 500 error.
$company = null;
$client_count = 0;
$assistant_count = 0;
try {
    $company = $database->select(
        "select * from v_xcall_company where domain_uuid = :domain_uuid limit 1",
        ["domain_uuid" => $domain_uuid],
        "row"
    );
    $client_count = (int)$database->select(
        "select count(*) from v_xcall_clients where domain_uuid = :domain_uuid",
        ["domain_uuid" => $domain_uuid],
        "var"
    );
    $assistant_count = (int)$database->select(
        "select count(*) from v_xcall_assistants where domain_uuid = :domain_uuid",
        ["domain_uuid" => $domain_uuid],
        "var"
    );
} catch (Throwable $e) {
    $setup_error = $e->getMessage();
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Admin Panel — XCall</title>
<link rel="stylesheet" href="style.css">
</head>
<body class="xcall-ai">
<div class="xcall-shell">
  <aside class="xcall-sidebar">
    <div class="xcall-brand"><span class="mark">X</span><span class="name">XCall</span></div>
    <nav class="xcall-nav">
      <div class="nav-label">Admin Panel</div>
      <a href="index.php" class="active">Dashboard</a>
      <a href="system.php">System &amp; Company</a>
      <a href="clients.php">Clients</a>
      <a href="softphone.php">Softphone</a>
      <div class="nav-label">AI Suite</div>
      <a href="../ai-assistant/assistants.php">AI Assistants</a>
      <a href="../webphone/index.html">Web Softphone</a>
      <a href="../../core/dashboard/">Back to Portal</a>
    </nav>
  </aside>

  <main class="xcall-main">
    <div class="xcall-topbar">
      <h1>Admin Panel</h1>
      <span style="color:var(--x-c-muted);font-size:13px">
        System: <strong><?= htmlspecialchars($company["system_name"] ?? "XCall") ?></strong>
      </span>
    </div>
    <p style="color:var(--x-c-muted);margin:0 0 24px">
      Name your system, enter your company details, maintain client data, and
      customize the softphone — all in one place.
    </p>
    <?php if (!empty($setup_error)): ?>
      <div style="background:rgba(255,180,0,.12);border:1px solid rgba(255,180,0,.4);color:#ffd;
                  padding:10px 14px;border-radius:8px;margin:0 0 16px;font-size:13px">
        ⚠ Admin data tables not found — apply <code>portal/ai-assistant/schema.sql</code>
        manually, or re-run the installer. (<code><?= htmlspecialchars((string)$setup_error) ?></code>)
      </div>
    <?php endif; ?>

    <div class="xcall-list" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px">
      <div class="xcall-card">
        <h3 class="card-title">System &amp; Company</h3>
        <div class="card-meta">Brand name, palette, logo, and company details.</div>
        <div class="card-actions">
          <a class="xcall-btn xcall-btn-outline" href="system.php">Configure</a>
        </div>
      </div>
      <div class="xcall-card">
        <h3 class="card-title">Clients</h3>
        <div class="card-meta"><?= $client_count ?> client(s) on file.</div>
        <div class="card-actions">
          <a class="xcall-btn xcall-btn-outline" href="clients.php">Manage clients</a>
        </div>
      </div>
      <div class="xcall-card">
        <h3 class="card-title">Softphone</h3>
        <div class="card-meta">Theme, ringtone, hold music, and call behavior.</div>
        <div class="card-actions">
          <a class="xcall-btn xcall-btn-outline" href="softphone.php">Customize</a>
        </div>
      </div>
      <div class="xcall-card">
        <h3 class="card-title">AI Assistants</h3>
        <div class="card-meta"><?= $assistant_count ?> assistant(s) configured.</div>
        <div class="card-actions">
          <a class="xcall-btn xcall-btn-outline" href="../ai-assistant/assistants.php">Open AI Suite</a>
        </div>
      </div>
    </div>
  </main>
</div>
</body>
</html>
