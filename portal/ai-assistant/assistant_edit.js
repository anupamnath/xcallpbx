/* XCall — AI Assistant editor logic. */
(function () {
  'use strict';

  var ASSISTANT_UUID = new URLSearchParams(location.search).get('assistant_uuid') || '';

  function $(id) { return document.getElementById(id); }
  function toast(msg, kind) {
    var el = document.createElement('div');
    el.className = 'xcall-toast ' + (kind || 'ok');
    el.textContent = msg;
    document.body.appendChild(el);
    requestAnimationFrame(function () { el.classList.add('show'); });
    setTimeout(function () { el.classList.remove('show'); setTimeout(function () { el.remove(); }, 300); }, 2600);
  }

  // ---- tabs ------------------------------------------------------------ //
  document.querySelectorAll('.xcall-tabs button').forEach(function (btn) {
    btn.addEventListener('click', function () {
      document.querySelectorAll('.xcall-tabs button').forEach(function (b) { b.classList.remove('active'); });
      document.querySelectorAll('.xcall-tabpane').forEach(function (p) { p.style.display = 'none'; });
      btn.classList.add('active');
      $('tab-' + btn.dataset.tab).style.display = 'flex';
    });
  });

  // ---- provider-aware fields ------------------------------------------ //
  var providerDefaults = {
    openai:        { model: 'gpt-4o-mini',          base: 'https://api.openai.com/v1',      needsKey: true,  hint: 'e.g. gpt-4o-mini' },
    anthropic:     { model: 'claude-3-5-sonnet-latest', base: 'https://api.anthropic.com/v1', needsKey: true,  hint: 'e.g. claude-3-5-sonnet-latest' },
    gemini:        { model: 'gemini-1.5-pro',        base: 'https://generativelanguage.googleapis.com/v1beta/openai', needsKey: true,  hint: 'e.g. gemini-1.5-pro' },
    groq:          { model: 'llama-3.3-70b-versatile', base: 'https://api.groq.com/openai/v1', needsKey: true,  hint: 'e.g. llama-3.3-70b-versatile' },
    openai_compatible: { model: '',                  base: '',                                  needsKey: true,  hint: 'model name on your endpoint' },
    ollama:        { model: 'llama3.1',              base: 'http://127.0.0.1:11434',           needsKey: false, hint: 'e.g. llama3.1' }
  };

  function updateProviderUI() {
    var p = $('providerSelect').value;
    var cfg = providerDefaults[p] || providerDefaults.openai;
    $('apiKeyField').style.display = cfg.needsKey ? 'flex' : 'none';
    $('localHint').style.display = p === 'ollama' ? 'flex' : 'none';
    $('modelHint').textContent = cfg.hint;
    if (cfg.model && !document.querySelector('[name=assistant_model]').value.trim()) {
      document.querySelector('[name=assistant_model]').value = cfg.model;
    }
    if (cfg.base && !document.querySelector('[name=assistant_api_base_url]').value.trim()) {
      document.querySelector('[name=assistant_api_base_url]').value = cfg.base;
    }
  }
  $('providerSelect').addEventListener('change', updateProviderUI);
  updateProviderUI();

  // ---- collect form ---------------------------------------------------- //
  function collectForm() {
    var data = { assistant_uuid: ASSISTANT_UUID };
    var form = $('assistantForm');
    new FormData(form).forEach(function (value, key) {
      if (key === 'assistant_enabled_check') return;
      data[key] = value;
    });
    // enable checkbox overrides the <select> for new records
    if ($('enableSwitch')) data.assistant_enabled = $('enableSwitch').checked;
    // only send the api key if the user typed a new one
    var keyInput = document.querySelector('[name=assistant_api_key]');
    if (keyInput && !keyInput.value.trim()) delete data.assistant_api_key;
    return data;
  }

  // ---- save ------------------------------------------------------------ //
  $('saveBtn').addEventListener('click', function () {
    var name = document.querySelector('[name=assistant_name]').value.trim();
    if (!name) { toast('Name is required', 'err'); return; }
    var btn = this;
    btn.disabled = true;
    btn.textContent = 'Saving…';

    fetch('assistant_api.php?action=save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(collectForm())
    })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (res.error) throw new Error(res.error);
        toast('Assistant saved');
        $('assistantName').textContent = document.querySelector('[name=assistant_name]').value.trim();
        if (!ASSISTANT_UUID) {
          // reload so the uuid is embedded; the saved record is now active
          setTimeout(function () { location.href = 'assistants.php'; }, 900);
        }
      })
      .catch(function (e) { toast('Save failed: ' + e.message, 'err'); })
      .finally(function () { btn.disabled = false; btn.textContent = 'Save assistant'; });
  });

  // ---- test conversation ---------------------------------------------- //
  $('testBtn').addEventListener('click', function () {
    var name = document.querySelector('[name=assistant_name]').value.trim() || 'Untitled';
    toast('Testing "' + name + '" — dial extension 5000 and talk to the assistant.');
    // a real test call can be triggered from the web softphone; this is a hint.
  });
})();
