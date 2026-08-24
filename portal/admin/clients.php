<?php
/**
 * XCall — Admin Panel: Clients (CRM).
 * Maintain the data on your clients: contacts, companies, notes, status.
 */

require_once dirname(__DIR__) . "/resources/require.php";
require_once dirname(__DIR__) . "/ai-assistant/api_helpers.php";

if (empty($_SESSION["username"])) {
    header("Location: " . PROJECT_PATH . "/login.php");
    exit;
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Clients — XCall Admin</title>
<link rel="stylesheet" href="../ai-assistant/style.css">
<link rel="stylesheet" href="style.css">
</head>
<body class="xcall-ai">
<div class="xcall-shell">
  <aside class="xcall-sidebar">
    <div class="xcall-brand"><span class="mark">X</span><span class="name">XCall</span></div>
    <nav class="xcall-nav">
      <div class="nav-label">Admin Panel</div>
      <a href="index.php">Dashboard</a>
      <a href="system.php">System &amp; Company</a>
      <a href="clients.php" class="active">Clients</a>
      <a href="softphone.php">Softphone</a>
      <div class="nav-label">AI Suite</div>
      <a href="../ai-assistant/assistants.php">AI Assistants</a>
      <a href="../webphone/index.html">Web Softphone</a>
      <a href="../../core/dashboard/">Back to Portal</a>
    </nav>
    <div class="xcall-sidebar-footer">
      <span>Signed in as <strong><?= htmlspecialchars($_SESSION["username"] ?? "guest") ?></strong></span>
      <a href="<?= PROJECT_PATH ?>/logout.php">Log out</a>
    </div>
  </aside>

  <main class="xcall-main">
    <div class="xcall-topbar">
      <div>
        <h1>Clients</h1>
        <p class="xcall-subtitle">Maintain contacts, companies, notes and status for your clients.</p>
      </div>
      <button class="xcall-btn xcall-btn-primary" id="addBtn">+ Add client</button>
    </div>

    <div class="xcall-table-wrap">
      <table class="xcall-table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Phone</th>
            <th>Email</th>
            <th>Company</th>
            <th>Status</th>
            <th style="width:150px">Actions</th>
          </tr>
        </thead>
        <tbody id="clientRows">
          <tr><td colspan="6" style="text-align:center;color:#94a3b8;padding:24px">Loading…</td></tr>
        </tbody>
      </table>
    </div>
  </main>
</div>

<!-- modal -->
<div class="xcall-modal-backdrop" id="modal">
  <div class="xcall-modal">
    <h3 id="modalTitle">Add client</h3>
    <form id="clientForm" class="xcall-form" style="gap:12px">
      <input type="hidden" name="client_uuid">
      <div class="xcall-grid">
        <div class="xcall-field">
          <label>Name *</label>
          <input type="text" name="client_name" required>
        </div>
        <div class="xcall-field">
          <label>Status</label>
          <select name="client_status">
            <option value="active">Active</option>
            <option value="lead">Lead</option>
            <option value="inactive">Inactive</option>
          </select>
        </div>
      </div>
      <div class="xcall-grid">
        <div class="xcall-field">
          <label>Phone</label>
          <input type="text" name="client_phone">
        </div>
        <div class="xcall-field">
          <label>Email</label>
          <input type="email" name="client_email">
        </div>
      </div>
      <div class="xcall-field">
        <label>Company</label>
        <input type="text" name="client_company">
      </div>
      <div class="xcall-field">
        <label>Notes</label>
        <textarea name="client_notes" rows="3"></textarea>
      </div>
      <div style="display:flex;justify-content:flex-end;gap:10px;margin-top:6px">
        <button type="button" class="xcall-btn xcall-btn-outline" id="cancelBtn">Cancel</button>
        <button type="submit" class="xcall-btn xcall-btn-primary">Save client</button>
      </div>
    </form>
  </div>
</div>

<div class="xcall-toast" id="toast"></div>
<script src="admin.js"></script>
<script src="clients.js"></script>
</body>
</html>
