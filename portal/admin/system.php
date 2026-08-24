<?php
/**
 * XCall — Admin Panel: System & Company.
 * Name the system, set the brand palette, and enter company details.
 */

require_once dirname(__DIR__, 2) . "/resources/require.php";
require_once dirname(__DIR__) . "/ai-assistant/api_helpers.php";

if (empty($_SESSION["username"])) {
    header("Location: " . PROJECT_PATH . "/login.php");
    exit;
}

$domain_uuid = $_SESSION["domain_uuid"] ?? "00000000-0000-0000-0000-000000000000";
$company = $database->select(
    "select * from v_xcall_company where domain_uuid = :domain_uuid limit 1",
    ["domain_uuid" => $domain_uuid],
    "row"
);
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>System &amp; Company — XCall Admin</title>
<link rel="stylesheet" href="style.css">
</head>
<body class="xcall-ai">
<div class="xcall-shell">
  <aside class="xcall-sidebar">
    <div class="xcall-brand"><span class="mark">X</span><span class="name">XCall</span></div>
    <nav class="xcall-nav">
      <div class="nav-label">Admin Panel</div>
      <a href="index.php">Dashboard</a>
      <a href="system.php" class="active">System &amp; Company</a>
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
      <h1>System &amp; Company</h1>
      <button class="xcall-btn xcall-btn-primary" id="saveBtn">Save changes</button>
    </div>

    <form class="xcall-form" id="companyForm">

      <div class="xcall-section-title">Branding</div>
      <div class="xcall-grid">
        <div class="xcall-field">
          <label>System name <span class="hint">— replaces "XCall" across the portal</span></label>
          <input type="text" name="system_name" value="<?= htmlspecialchars($company["system_name"] ?? "XCall") ?>">
        </div>
        <div class="xcall-field">
          <label>Tagline</label>
          <input type="text" name="tagline" value="<?= htmlspecialchars($company["tagline"] ?? "") ?>">
        </div>
      </div>
      <div class="xcall-grid">
        <div class="xcall-field">
          <label>Primary color</label>
          <input type="color" name="primary_color" value="<?= htmlspecialchars($company["primary_color"] ?? "#6366f1") ?>" style="height:42px">
        </div>
        <div class="xcall-field">
          <label>Accent color</label>
          <input type="color" name="accent_color" value="<?= htmlspecialchars($company["accent_color"] ?? "#22d3ee") ?>" style="height:42px">
        </div>
      </div>
      <div class="xcall-field">
        <label>Logo path <span class="hint">— relative to the web root (SVG/PNG)</span></label>
        <input type="text" name="logo_path" value="<?= htmlspecialchars($company["logo_path"] ?? "/themes/default/images/xcall_logo.svg") ?>">
      </div>

      <div class="xcall-section-title">Company details</div>
      <div class="xcall-grid">
        <div class="xcall-field">
          <label>Company name</label>
          <input type="text" name="company_name" value="<?= htmlspecialchars($company["company_name"] ?? "") ?>">
        </div>
        <div class="xcall-field">
          <label>Phone</label>
          <input type="text" name="company_phone" value="<?= htmlspecialchars($company["company_phone"] ?? "") ?>">
        </div>
      </div>
      <div class="xcall-grid">
        <div class="xcall-field">
          <label>Email</label>
          <input type="email" name="company_email" value="<?= htmlspecialchars($company["company_email"] ?? "") ?>">
        </div>
        <div class="xcall-field">
          <label>Website</label>
          <input type="text" name="company_website" value="<?= htmlspecialchars($company["company_website"] ?? "") ?>">
        </div>
      </div>
      <div class="xcall-field">
        <label>Address</label>
        <textarea name="company_address" rows="3"><?= htmlspecialchars($company["company_address"] ?? "") ?></textarea>
      </div>

    </form>
  </main>
</div>

<div class="xcall-toast" id="toast"></div>
<script src="admin.js"></script>
<script>
(function () {
  var form = document.getElementById('companyForm');
  document.getElementById('saveBtn').addEventListener('click', function () {
    var data = {};
    new FormData(form).forEach(function (v, k) { data[k] = v; });
    fetch('admin_api.php?action=company_save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data)
    })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (res.error) throw new Error(res.error);
        toast('Company settings saved');
      })
      .catch(function (e) { toast('Save failed: ' + e.message, 'err'); });
  });
})();
</script>
</body>
</html>
