<?php
/**
 * XCall — Admin Panel: Softphone customizations.
 * Theme, ringtone, hold music, auto-answer for the in-browser softphone.
 */

require_once dirname(__DIR__) . "/resources/require.php";
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
<title>Softphone — XCall Admin</title>
<link rel="stylesheet" href="../ai-assistant/style.css">
<link rel="stylesheet" href="style.css">
</head>
<body class="xcall-ai">
<div class="xcall-shell">
  <aside class="xcall-sidebar">
    <div class="xcall-brand"><span class="mark">X</span><span class="name">XCall&nbsp;PBX</span></div>
    <nav class="xcall-nav">
      <div class="nav-label">Admin Panel</div>
      <a href="index.php">Dashboard</a>
      <a href="system.php">System &amp; Company</a>
      <a href="clients.php">Clients</a>
      <a href="softphone.php" class="active">Softphone</a>
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
        <h1>Softphone</h1>
        <p class="xcall-subtitle">Theme, ringtone, hold music, and call behavior for the web phone.</p>
      </div>
      <button class="xcall-btn xcall-btn-primary" id="saveBtn">Save changes</button>
    </div>

    <form class="xcall-form" id="softphoneForm">
      <div class="xcall-grid">
        <div class="xcall-field">
          <label>Theme</label>
          <select name="softphone_theme">
            <?php
            $theme = $company["softphone_theme"] ?? "dark";
            foreach (["dark" => "Dark (XCall)", "light" => "Light", "system" => "System default"] as $v => $l) {
                $sel = $theme === $v ? " selected" : "";
                echo "<option value=\"$v\"$sel>$l</option>\n";
            }
            ?>
          </select>
        </div>
        <div class="xcall-field">
          <label>Ringtone</label>
          <select name="softphone_ringtone">
            <?php
            $ring = $company["softphone_ringtone"] ?? "default";
            foreach (["default" => "Default", "classic" => "Classic", "digital" => "Digital", "soft" => "Soft"] as $v => $l) {
                $sel = $ring === $v ? " selected" : "";
                echo "<option value=\"$v\"$sel>$l</option>\n";
            }
            ?>
          </select>
        </div>
      </div>
      <div class="xcall-grid">
        <div class="xcall-field">
          <label>Hold music <span class="hint">— FreeSWITCH local stream</span></label>
          <input type="text" name="softphone_hold_music"
                 value="<?= htmlspecialchars($company["softphone_hold_music"] ?? "local_stream://moh") ?>">
        </div>
        <div class="xcall-field">
          <label>Default assistant for inbound calls</label>
          <select name="assistant_default_uuid">
            <option value="">— None (use most recently updated) —</option>
            <?php
            $default_assistant = $company["assistant_default_uuid"] ?? "";
            $assistants = $database->select(
                "select assistant_uuid, assistant_name from v_xcall_assistants "
                . "where domain_uuid = :domain_uuid order by assistant_name",
                ["domain_uuid" => $domain_uuid],
                "all"
            ) ?: [];
            foreach ($assistants as $a) {
                $sel = $a["assistant_uuid"] === $default_assistant ? " selected" : "";
                echo '<option value="' . htmlspecialchars($a["assistant_uuid"]) . '"' . $sel . '>'
                   . htmlspecialchars($a["assistant_name"]) . "</option>\n";
            }
            ?>
          </select>
        </div>
      </div>
      <div class="xcall-check">
        <input type="checkbox" id="autoAnswer" <?= !empty($company["softphone_auto_answer"]) ? "checked" : "" ?>>
        <label for="autoAnswer">Auto-answer incoming calls</label>
      </div>
      <div class="xcall-check">
        <input type="checkbox" id="spEnabled" <?= ($company["softphone_enabled"] ?? "true") === "true" || !empty($company["softphone_enabled"]) ? "checked" : "" ?>>
        <label for="spEnabled">Enable the web softphone for agents</label>
      </div>

      <div class="xcall-section-title">Preview</div>
      <div class="sp-preview">
        <div class="sp-avatar">X</div>
        <div class="sp-line">
          <?= htmlspecialchars($company["company_name"] ?: "Your Company") ?>
          <small>Incoming call · 1000 · <span id="previewRing"><?= htmlspecialchars($company["softphone_ringtone"] ?? "default") ?> ring</span></small>
        </div>
      </div>
    </form>
  </main>
</div>

<div class="xcall-toast" id="toast"></div>
<script src="admin.js"></script>

<script>
(function () {
  var form = document.getElementById('softphoneForm');
  var ringSel = form.softphone_ringtone;
  ringSel.addEventListener('change', function () {
    document.getElementById('previewRing').textContent = ringSel.value + ' ring';
  });
  document.getElementById('saveBtn').addEventListener('click', function () {
    var data = {};
    new FormData(form).forEach(function (v, k) {
      if (k === 'assistant_default_uuid') { data.assistant_default_uuid = v; return; }
      data[k] = v;
    });
    data.softphone_auto_answer = document.getElementById('autoAnswer').checked ? 'true' : 'false';
    data.softphone_enabled = document.getElementById('spEnabled').checked ? 'true' : 'false';
    fetch('admin_api.php?action=softphone_save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data)
    })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (res.error) throw new Error(res.error);
        toast('Softphone settings saved');
      })
      .catch(function (e) { toast('Save failed: ' + e.message, 'err'); });
  });
})();
</script>
</body>
</html>

