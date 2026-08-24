<?php
/**
 * XCall — local landing page (served at "/" by the dev router).
 * Mirrors the look of the portal: dark sidebar, brand, quick links.
 */
$php_v = phpversion();
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>XCall — Local Demo Portal</title>
<style>
  :root {
    --bg:#0f172a; --surface:#1e293b; --panel:#111c33;
    --cyan:#22d3ee; --indigo:#6366f1; --indigo-lt:#818cf8;
    --text:#e2e8f0; --muted:#94a3b8;
  }
  * { box-sizing:border-box; }
  body { margin:0; font-family:"Segoe UI", system-ui, sans-serif; background:var(--bg); color:var(--text); min-height:100vh; }
  .shell { display:flex; min-height:100vh; }
  aside { width:240px; background:var(--panel); padding:18px 0; flex-shrink:0; border-right:1px solid #1e293b; }
  .brand { display:flex; align-items:center; gap:10px; padding:0 20px 18px; border-bottom:1px solid #1e293b; }
  .brand .mark { width:32px; height:32px; border-radius:9px; background:linear-gradient(135deg,var(--cyan),var(--indigo)); display:inline-flex; align-items:center; justify-content:center; font-weight:800; color:#fff; }
  .brand .name { font-weight:700; color:#fff; letter-spacing:.5px; }
  nav { margin-top:12px; }
  nav .lbl { font-size:11px; text-transform:uppercase; letter-spacing:1px; color:#64748b; padding:12px 20px 6px; }
  nav a { display:block; padding:8px 20px; color:#cbd5e1; text-decoration:none; font-size:14px; }
  nav a:hover { background:#1e293b; color:#fff; }
  nav a.on { background:#1e293b; color:var(--cyan); border-left:3px solid var(--cyan); }
  main { flex:1; padding:32px 40px; max-width:960px; }
  h1 { margin:0 0 6px; font-size:24px; }
  .sub { color:var(--muted); margin-bottom:28px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:16px; }
  .card { background:var(--surface); border:1px solid #334155; border-radius:12px; padding:20px; text-decoration:none; color:var(--text); transition:transform .12s ease, border-color .12s ease; display:block; }
  .card:hover { transform:translateY(-2px); border-color:var(--indigo); }
  .card h3 { margin:0 0 8px; font-size:16px; color:#fff; }
  .card p { margin:0; color:var(--muted); font-size:13px; line-height:1.5; }
  .card .tag { display:inline-block; margin-top:12px; font-size:12px; color:var(--cyan); font-weight:600; }
  .status { margin-top:32px; background:var(--panel); border:1px solid #334155; border-radius:12px; padding:18px 20px; font-size:13px; }
  .status h3 { margin:0 0 10px; font-size:14px; color:#fff; }
  .row { display:flex; justify-content:space-between; padding:4px 0; border-bottom:1px dashed #1e293b; }
  .row:last-child { border-bottom:none; }
  .ok { color:#4ade80; } .warn { color:#facc15; }
</style>
</head>
<body>
<div class="shell">
  <aside>
    <div class="brand"><span class="mark">X</span><span class="name">XCall</span></div>
    <nav>
      <div class="lbl">Workspace</div>
      <a href="/" class="on">Dashboard</a>
      <a href="/ai-assistant/assistants.php">AI Assistants</a>
      <a href="/admin/index.php">Admin Panel</a>
      <a href="/webphone/index.html">Web Softphone</a>
      <div class="lbl">System</div>
      <a href="/ai-assistant/assistant_api.php?action=list">Assistant API (JSON)</a>
    </nav>
  </aside>
  <main>
    <h1>XCall Portal</h1>
    <div class="sub">Local demo mode — FusionPBX + FreeSWITCH are not running here; you are auto-logged-in as <b>admin</b>.</div>
    <div class="grid">
      <a class="card" href="/ai-assistant/assistants.php">
        <h3>AI Assistants</h3>
        <p>Telnyx-style assistant manager — write the context, pick an LLM via API key or your local machine (Ollama / LM Studio / vLLM / llama.cpp), configure voice and handoff.</p>
        <span class="tag">Open AI Assistants &rarr;</span>
      </a>
      <a class="card" href="/admin/index.php">
        <h3>Admin Panel</h3>
        <p>Name your system, enter company details, maintain client data, and customize the softphone.</p>
        <span class="tag">Open Admin Panel &rarr;</span>
      </a>
      <a class="card" href="/webphone/index.html">
        <h3>Web Softphone</h3>
        <p>In-browser WebRTC phone (SIP.js). Logged-in clients dial straight from the portal — no desktop app. Calls require the FreeSWITCH server.</p>
        <span class="tag">Open Softphone &rarr;</span>
      </a>
    </div>
    <div class="status">
      <h3>Demo status</h3>
      <div class="row"><span>Portal (PHP <?= htmlspecialchars($php_v) ?>)</span><span class="ok">Running</span></div>
      <div class="row"><span>Storage</span><span>SQLite (local demo)</span></div>
      <div class="row"><span>FreeSWITCH / verto</span><span class="warn">Not running (needs VPS / Docker)</span></div>
      <div class="row"><span>AI agent (ESL)</span><span class="warn">Dry-run only on this machine</span></div>
    </div>
  </main>
</div>
</body>
</html>
