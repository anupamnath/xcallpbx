<?php
/**
 * XCall — AI Assistant editor.
 * Create / edit an assistant: context (instructions), greeting, model
 * provider (API key or local machine), voice, handoff, and call settings.
 */

require_once dirname(__DIR__, 2) . "/resources/require.php";
require_once __DIR__ . "/api_helpers.php";

if (empty($_SESSION["username"])) {
    header("Location: " . PROJECT_PATH . "/login.php");
    exit;
}

$assistant_uuid = $_GET["assistant_uuid"] ?? "";
$duplicate = !empty($_GET["duplicate"]);
$assistant = null;

if ($assistant_uuid) {
    $domain_uuid = $_SESSION["domain_uuid"] ?? "00000000-0000-0000-0000-000000000000";
    $assistant = $database->select(
        "select * from v_xcall_assistants "
        . "where assistant_uuid = :uuid and domain_uuid = :domain_uuid",
        ["uuid" => $assistant_uuid, "domain_uuid" => $domain_uuid],
        "row"
    );
    if ($assistant) {
        $assistant["assistant_api_key_enc"] = ""; // never send the real key to the page
        if ($duplicate) {
            $assistant["assistant_uuid"] = "";
            $assistant["assistant_name"] .= " (copy)";
        }
    }
}

$is_new = empty($assistant_uuid) || $duplicate || !$assistant;
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= $is_new ? "New" : "Edit" ?> AI Assistant — XCall</title>
<link rel="stylesheet" href="style.css">
</head>
<body class="xcall-ai">
<div class="xcall-shell">
  <aside class="xcall-sidebar">
    <div class="xcall-brand"><span class="mark">X</span><span class="name">XCall</span></div>
    <nav class="xcall-nav">
      <div class="nav-label">AI Suite</div>
      <a href="assistants.php">AI Assistants</a>
      <a href="assistants.php">Assistants</a>
      <a href="#">Tools</a>
      <div class="nav-label">Deploy</div>
      <a href="../webphone/index.html">Web Softphone</a>
      <a href="../../core/dashboard/">Back to Portal</a>
    </nav>
  </aside>

  <main class="xcall-main">
    <div class="xcall-topbar">
      <div>
        <a href="assistants.php" style="color:var(--x-c-accent);text-decoration:none;font-size:13px">&larr; Back to AI Assistants</a>
        <h1 id="assistantName"><?= htmlspecialchars($assistant["assistant_name"] ?? "New AI Assistant") ?></h1>
      </div>
      <div style="display:flex;gap:10px">
        <button class="xcall-btn xcall-btn-outline" id="testBtn">Test conversation</button>
        <button class="xcall-btn xcall-btn-primary" id="saveBtn">Save assistant</button>
      </div>
    </div>

    <div class="xcall-tabs">
      <button class="active" data-tab="agent">Agent</button>
      <button data-tab="voice">Voice &amp; Speech</button>
      <button data-tab="handoff">Handoff</button>
      <button data-tab="settings">Settings</button>
    </div>

    <form class="xcall-form" id="assistantForm">

      <!-- ============ Agent tab ============ -->
      <div class="xcall-tabpane" id="tab-agent">
        <div class="xcall-field">
          <label>Name</label>
          <input type="text" name="assistant_name" required
                 value="<?= htmlspecialchars($assistant["assistant_name"] ?? "") ?>">
        </div>

        <div class="xcall-field">
          <label>Greeting <span class="hint">— spoken first, before the caller says anything</span></label>
          <textarea name="assistant_greeting"><?= htmlspecialchars($assistant["assistant_greeting"] ?? "") ?></textarea>
        </div>

        <div class="xcall-field">
          <label>Instructions / context <span class="hint">— how the assistant should behave, what it knows, when to escalate</span></label>
          <textarea name="assistant_instructions" style="min-height:200px"><?= htmlspecialchars($assistant["assistant_instructions"] ?? "") ?></textarea>
        </div>

        <div class="xcall-grid">
          <div class="xcall-field">
            <label>Model provider</label>
            <select name="assistant_provider" id="providerSelect">
              <?php
              $providers = [
                  "openai" => "OpenAI (API key)",
                  "anthropic" => "Anthropic Claude (API key)",
                  "gemini" => "Google Gemini (API key)",
                  "groq" => "Groq (API key)",
                  "openai_compatible" => "Any OpenAI-compatible endpoint (API key)",
                  "ollama" => "Local machine (Ollama — no API key)",
              ];
              $cur = $assistant["assistant_provider"] ?? "openai";
              foreach ($providers as $val => $label) {
                  $sel = $val === $cur ? " selected" : "";
                  echo "<option value=\"$val\"$sel>$label</option>\n";
              }
              ?>
            </select>
          </div>
          <div class="xcall-field">
            <label>Model <span class="hint" id="modelHint">e.g. gpt-4o-mini</span></label>
            <input type="text" name="assistant_model"
                   value="<?= htmlspecialchars($assistant["assistant_model"] ?? "") ?>"
                   placeholder="gpt-4o-mini">
          </div>
        </div>

        <div class="xcall-grid">
          <div class="xcall-field" id="apiKeyField">
            <label>API key</label>
            <input type="password" name="assistant_api_key" autocomplete="new-password"
                   placeholder="<?= !empty($assistant["assistant_api_key_enc"]) ? "•••••••• (leave blank to keep current)" : "sk-…" ?>">
          </div>
          <div class="xcall-field" id="baseUrlField">
            <label>API base URL <span class="hint">— for custom / local endpoints</span></label>
            <input type="text" name="assistant_api_base_url"
                   value="<?= htmlspecialchars($assistant["assistant_api_base_url"] ?? "") ?>"
                   placeholder="https://api.openai.com/v1">
          </div>
        </div>

        <div class="xcall-field" id="localHint" style="display:none">
          <div style="background:#f0fdf4;border:1px solid #bbf7d0;border-radius:8px;padding:10px 14px;font-size:13px">
            <strong>Local machine mode</strong> — point the base URL at your Ollama server
            (e.g. <code>http://192.168.1.10:11434</code> or the Docker service name) and set the model
            (e.g. <code>llama3.1</code>). No API key needed.
          </div>
        </div>

        <div class="xcall-grid">
          <div class="xcall-field">
            <label>Temperature</label>
            <input type="number" step="0.1" min="0" max="2" name="assistant_temperature"
                   value="<?= htmlspecialchars($assistant["assistant_temperature"] ?? 0.7) ?>">
          </div>
          <div class="xcall-field">
            <label>Max tokens per reply</label>
            <input type="number" min="1" name="assistant_max_tokens"
                   value="<?= htmlspecialchars($assistant["assistant_max_tokens"] ?? 1024) ?>">
          </div>
        </div>
      </div>


      <!-- ============ Voice & Speech tab ============ -->
      <div class="xcall-tabpane" id="tab-voice" style="display:none">
        <div class="xcall-grid">
          <div class="xcall-field">
            <label>Speech-to-text engine</label>
            <select name="assistant_stt_engine">
              <?php
              foreach (["whisper" => "Whisper (local)", "vosk" => "Vosk (local)", "stub" => "Stub (test)"] as $v => $l) {
                  $sel = ($assistant["assistant_stt_engine"] ?? "whisper") === $v ? " selected" : "";
                  echo "<option value=\"$v\"$sel>$l</option>";
              }
              ?>
            </select>
          </div>
          <div class="xcall-field">
            <label>Text-to-speech engine</label>
            <select name="assistant_tts_engine">
              <?php
              foreach (["piper" => "Piper (local)", "espeak" => "eSpeak NG (local)", "stub" => "Stub (test)"] as $v => $l) {
                  $sel = ($assistant["assistant_tts_engine"] ?? "piper") === $v ? " selected" : "";
                  echo "<option value=\"$v\"$sel>$l</option>";
              }
              ?>
            </select>
          </div>
        </div>
        <div class="xcall-grid">
          <div class="xcall-field">
            <label>Voice</label>
            <input type="text" name="assistant_voice" value="<?= htmlspecialchars($assistant["assistant_voice"] ?? "default") ?>">
          </div>
          <div class="xcall-field">
            <label>Language</label>
            <input type="text" name="assistant_language" value="<?= htmlspecialchars($assistant["assistant_language"] ?? "en") ?>">
          </div>
        </div>
        <p class="hint" style="margin:0">The AI agent runs STT/TTS locally on the PBX server. The voice name maps to your
        local TTS voice (e.g. a Piper voice). For cloud TTS, connect a speech provider via the agent config.</p>
      </div>

      <!-- ============ Handoff tab ============ -->
      <div class="xcall-tabpane" id="tab-handoff" style="display:none">
        <div class="xcall-grid">
          <div class="xcall-field">
            <label>Specialist extension</label>
            <input type="text" name="assistant_handoff_extension"
                   value="<?= htmlspecialchars($assistant["assistant_handoff_extension"] ?? "7000") ?>">
          </div>
          <div class="xcall-field">
            <label>Silence retries before handoff</label>
            <input type="number" min="0" name="assistant_silence_retries"
                   value="<?= htmlspecialchars($assistant["assistant_silence_retries"] ?? 2) ?>">
          </div>
        </div>
        <div class="xcall-field">
          <label>Handoff message</label>
          <textarea name="assistant_handoff_message"><?= htmlspecialchars($assistant["assistant_handoff_message"] ?? "") ?></textarea>
          <span class="hint">Spoken before transferring the call to a human specialist.</span>
        </div>
        <p class="hint">When the assistant decides the caller needs a human, it plays this message and
        transfers the call to the specialist extension (ringing their web softphone).</p>
      </div>

      <!-- ============ Settings tab ============ -->
      <div class="xcall-tabpane" id="tab-settings" style="display:none">
        <div class="xcall-grid">
          <div class="xcall-field">
            <label>Max call duration (seconds)</label>
            <input type="number" min="10" name="assistant_max_call_seconds"
                   value="<?= htmlspecialchars($assistant["assistant_max_call_seconds"] ?? 900) ?>">
          </div>
          <div class="xcall-field">
            <label>Status</label>
            <select name="assistant_enabled">
              <?php
              $enabled = $assistant["assistant_enabled"] ?? true;
              $e_sel = $enabled ? " selected" : "";
              $d_sel = !$enabled ? " selected" : "";
              echo "<option value=\"1\"$e_sel>Active (route calls to this assistant)</option>";
              echo "<option value=\"0\"$d_sel>Disabled</option>";
              ?>
            </select>
          </div>
        </div>
        <div class="xcall-check">
          <input type="checkbox" id="enableSwitch" name="assistant_enabled_check" <?= $enabled ? "checked" : "" ?>>
          <label for="enableSwitch">Enabled</label>
        </div>
      </div>

    </form>
  </main>
</div>

<script src="assistant_edit.js"></script>
</body>
</html>

