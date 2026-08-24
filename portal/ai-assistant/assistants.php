<?php
/**
 * XCall — AI Assistants (list page).
 * Lists configured assistants with create/edit/delete actions.
 */

require_once dirname(__DIR__, 2) . "/resources/require.php";
require_once __DIR__ . "/api_helpers.php";

if (empty($_SESSION["username"])) {
    header("Location: " . PROJECT_PATH . "/login.php");
    exit;
}

$domain_uuid = $_SESSION["domain_uuid"] ?? "00000000-0000-0000-0000-000000000000";

// load the list for server-side rendering (keeps first paint fast)
$rows = [];
try {
    $rows = $database->select(
        "select assistant_uuid, assistant_name, assistant_provider, assistant_model, "
        . "assistant_enabled, assistant_updated "
        . "from v_xcall_assistants where domain_uuid = :domain_uuid "
        . "order by assistant_updated desc",
        ["domain_uuid" => $domain_uuid],
        "all"
    ) ?: [];
} catch (Throwable $e) {
    // table not created yet — show the setup hint
    $rows = [];
    $setup_error = $e->getMessage();
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AI Assistants — XCall</title>
<link rel="stylesheet" href="style.css">
</head>
<body class="xcall-ai">
<div class="xcall-shell">
  <aside class="xcall-sidebar">
    <div class="xcall-brand"><span class="mark">X</span><span class="name">XCall</span></div>
    <nav class="xcall-nav">
      <div class="nav-label">AI Suite</div>
      <a href="assistants.php" class="active">AI Assistants</a>
      <a href="assistants.php">Assistants</a>
      <a href="#">Tools</a>
      <div class="nav-label">Speech</div>
      <a href="#">Text-to-Speech</a>
      <a href="#">Speech-to-Text</a>
      <div class="nav-label">Deploy</div>
      <a href="../webphone/index.html">Web Softphone</a>
      <a href="../admin/index.php">Admin Panel</a>
      <a href="../../core/dashboard/">Back to Portal</a>
    </nav>
  </aside>

  <main class="xcall-main">
    <div class="xcall-topbar">
      <h1>AI Assistants</h1>
      <a class="xcall-btn xcall-btn-primary" href="assistant_edit.php">+ Create AI Assistant</a>
    </div>

    <?php if (!empty($setup_error) && strpos($setup_error, "v_xcall_assistants") !== false): ?>
      <div class="xcall-empty">
        <h3>Database not initialised yet</h3>
        <p>Run the schema to create the AI Assistant tables:</p>
        <p><code>psql -U fusionpbx -d fusionpbx -f portal/ai-assistant/schema.sql</code></p>
      </div>
    <?php elseif (empty($rows)): ?>
      <div class="xcall-empty">
        <h3>No AI assistants yet</h3>
        <p>Create your first assistant — configure the context it should follow<br>
           and connect it to an LLM via API key or your local machine.</p>
        <p style="margin-top:14px"><a class="xcall-btn xcall-btn-primary" href="assistant_edit.php">+ Create AI Assistant</a></p>
      </div>
    <?php else: ?>
      <div class="xcall-list">
        <?php foreach ($rows as $r): ?>
        <div class="xcall-card">
          <h3 class="card-title"><?= htmlspecialchars($r["assistant_name"]) ?></h3>
          <div class="card-meta">
            <?= htmlspecialchars($r["assistant_provider"]) ?> ·
            <?= htmlspecialchars($r["assistant_model"] ?: "model not set") ?>
            <?php if ($r["assistant_enabled"] === "t" || $r["assistant_enabled"] === true): ?>
              <span class="xcall-badge xcall-badge-ok">Active</span>
            <?php else: ?>
              <span class="xcall-badge xcall-badge-off">Disabled</span>
            <?php endif; ?>
          </div>
          <div class="card-actions">
            <a class="xcall-btn xcall-btn-outline" href="assistant_edit.php?assistant_uuid=<?= urlencode($r["assistant_uuid"]) ?>">Edit</a>
            <a class="xcall-btn xcall-btn-outline" href="assistant_edit.php?assistant_uuid=<?= urlencode($r["assistant_uuid"]) ?>&duplicate=1">Duplicate</a>
            <button class="xcall-btn xcall-btn-danger" data-delete="<?= htmlspecialchars($r["assistant_uuid"]) ?>">Delete</button>
          </div>
        </div>
        <?php endforeach; ?>
      </div>
    <?php endif; ?>
  </main>
</div>

<script>
document.addEventListener('click', function (e) {
  var btn = e.target.closest('[data-delete]');
  if (!btn) return;
  if (!confirm('Delete this AI assistant?')) return;
  fetch('assistant_api.php?action=delete&assistant_uuid=' + encodeURIComponent(btn.dataset.delete), { method: 'POST' })
    .then(function (r) { return r.json(); })
    .then(function (res) { location.reload(); })
    .catch(function () { alert('Delete failed'); });
});
</script>
</body>
</html>
