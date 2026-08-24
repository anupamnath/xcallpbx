/* XCall web softphone — main application logic.
 *
 * Uses SIP.js (0.15.x UMD) to register a SIP over WebSocket client to
 * FreeSWITCH, letting the agent make/receive calls from the portal after
 * login. Configuration is fetched from config.php (logged-in session), or the
 * user can register manually (ViciBox-style) with extension + password +
 * domain + WSS server.
 *
 * Requires the browser to allow microphone access (getUserMedia) and the
 * page to be served over HTTPS (or localhost) — WebRTC demands a secure
 * context.
 */

(function () {
  'use strict';

  // ------------------------------------------------------------------ //
  // state
  // ------------------------------------------------------------------ //
  var user = { registered: false, ua: null, cfg: null, mode: 'portal' };
  var session = null;        // active SIP.js InviteClientContext
  var timers = { tick: null };
  var callStart = null;
  var muted = false;
  var onHold = false;
  var regInProgress = false;

  // ------------------------------------------------------------------ //
  // dom helpers
  // ------------------------------------------------------------------ //
  function $(id) { return document.getElementById(id); }

  function setStatus(text, kind) {
    var el = $('status');
    el.textContent = text;
    el.className = 'status' + (kind ? ' status-' + kind : '');
  }

  function log(text) {
    var el = $('log');
    var line = document.createElement('div');
    line.textContent = '[' + new Date().toLocaleTimeString() + '] ' + text;
    el.appendChild(line);
    el.scrollTop = el.scrollHeight;
  }

  function setCaller(name, number) {
    $('callerName').textContent = name || '—';
    $('callerNumber').textContent = number || '—';
  }

  function show(el, on) {
    el.classList.toggle('hidden', !on);
  }

  // ------------------------------------------------------------------ //
  // registrar panel (account + registration state)
  // ------------------------------------------------------------------ //
  function setRegState(state, reason) {
    var dot = $('regDot');
    dot.className = 'reg-dot';
    if (state === 'Registered') { dot.classList.add('dot-ok'); }
    else if (state === 'Registering…' || state === 'Retrying…') { dot.classList.add('dot-busy'); }
    else if (state === 'Failed' || state === 'Error') { dot.classList.add('dot-err'); }
    else { dot.classList.add('dot-off'); }
    $('regState').textContent = state;
    show($('regReason'), !!reason);
    if (reason) { $('regReason').textContent = reason; }
  }

  function setRegistrar(cfg) {
    $('regExtension').textContent = (cfg && (cfg.extension || cfg.username)) || '—';
    var server = (cfg && cfg.domain) || '';
    if (!server && cfg && cfg.ws) { server = cfg.ws.replace(/^wss?:\/\//, ''); }
    $('regServer').textContent = server || '—';
  }

  function setRegistered(on) {
    user.registered = on;
    $('numberInput').disabled = !on;
  }

  // ------------------------------------------------------------------ //
  // duration ticker
  // ------------------------------------------------------------------ //
  function startTicker() {
    callStart = Date.now();
    stopTicker();
    timers.tick = setInterval(function () {
      var s = Math.floor((Date.now() - callStart) / 1000);
      var m = Math.floor(s / 60);
      var ss = ('0' + (s % 60)).slice(-2);
      $('callDuration').textContent = ('0' + m).slice(-2) + ':' + ss;
    }, 1000);
  }

  function stopTicker() {
    if (timers.tick) { clearInterval(timers.tick); timers.tick = null; }
    $('callDuration').textContent = '00:00';
  }
  // ------------------------------------------------------------------ //
  // SIP.js glue
  // ------------------------------------------------------------------ //
  function destroyUA() {
    if (user.ua) {
      try { user.ua.stop(); } catch (e) { /* already stopped */ }
      user.ua = null;
    }
    user.registered = false;
  }

  function makeUA(cfg) {
    destroyUA();
    var uri = 'sip:' + cfg.username + '@' + cfg.domain;

    var ua = new SIP.UA({
      uri: uri,
      wsServers: [cfg.ws],
      authorizationUser: cfg.username,
      password: cfg.password,
      displayName: cfg.displayName || 'XCall Agent',
      register: true,
      traceSip: false,
      logLevel: 'warn',
      registerExpires: 300,
      userAgentString: 'XCall-WebPhone/1.0',
      // keepalive so NAT stays open
      viaHost: cfg.domain,
      contactParams: ';transport=wss'
    });
    user.ua = ua;

    ua.on('registered', function () {
      regInProgress = false;
      setRegistered(true);
      setRegState('Registered', '');
      setStatus('Ready — ' + (cfg.extension || cfg.username), 'ok');
      log('Registered as ' + (cfg.extension || cfg.username) + ' @ ' + cfg.domain);
    });

    ua.on('unregistered', function () {
      setRegistered(false);
      if (regInProgress) {
        setRegState('Registering…');
        setStatus('Registering…', 'warn');
      } else {
        setRegState('Offline', 'registration expired — press Retry');
        setStatus('Offline', 'warn');
      }
    });

    ua.on('registrationFailed', function (e) {
      regInProgress = false;
      setRegistered(false);
      var cause = '';
      if (e) { cause = String(e.cause || e.reason || ''); }
      if (!cause) { cause = 'check credentials and WSS endpoint'; }
      setRegState('Failed', cause);
      setStatus('Registration failed', 'err');
      log('SIP registration failed — ' + cause);
    });

    ua.on('invite', function (incoming) {
      session = incoming;
      setCaller(incoming.remoteIdentity.displayName, incoming.remoteIdentity.uri.user);
      setStatus('Incoming call', 'ring');
      startTicker();
      show($('hangupBtn'), true);
      log('Incoming call from ' + incoming.remoteIdentity.uri.user);
    });

    return ua;
  }

  function currentUA() { return user.ua; }

  // ------------------------------------------------------------------ //
  // registration control
  // ------------------------------------------------------------------ //
  function registerWith(cfg) {
    user.cfg = cfg;
    setRegistrar(cfg);
    setRegistered(false);
    regInProgress = true;
    setRegState('Registering…');
    setStatus('Registering…', 'warn');
    log('Registering ' + (cfg.extension || cfg.username) + ' @ ' + cfg.domain + ' (' + cfg.ws + ')');
    user.ua = makeUA(cfg);
  }

  function loadPortalConfig() {
    setStatus('Loading config…');
    setRegState('Offline', '');
    fetch('config.php')
      .then(function (r) {
        return r.json().then(function (data) {
          return { ok: r.ok, status: r.status, data: data };
        });
      })
      .then(function (res) {
        if (!res.ok) {
          var e = new Error((res.data && res.data.error) || 'auth required');
          e.status = res.status;
          throw e;
        }
        var cfg = res.data;
        if (!cfg.username || !cfg.ws) { throw new Error('no SIP credentials in portal session'); }
        user.mode = 'portal';
        show($('authNotice'), false);
        registerWith(cfg);
      })
      .catch(function (err) {
        if (err && err.status === 401) {
          setRegistered(false);
          setRegState('Offline', 'not logged in');
          setStatus('Not logged in', 'err');
          setRegistrar({ extension: '', domain: window.location.hostname });
          show($('authNotice'), true);
          log('Not logged in — log into the XCall portal, or use manual setup below.');
        } else {
          setRegState('Error', err && err.message ? err.message : 'config load failed');
          setStatus('Config error', 'err');
          log('Config error: ' + (err && err.message ? err.message : err));
        }
      });
  }
  // ------------------------------------------------------------------ //
  // manual setup
  // ------------------------------------------------------------------ //
  function manualValues() {
    return {
      extension: $('mExt').value.trim(),
      username: $('mExt').value.trim(),
      password: $('mPass').value,
      domain: $('mDomain').value.trim(),
      ws: $('mWs').value.trim(),
      displayName: 'XCall Agent'
    };
  }

  function saveManual(cfg) {
    try { localStorage.setItem('xcall_manual', JSON.stringify(cfg)); } catch (e) { /* private mode */ }
  }

  function loadManual() {
    try { return JSON.parse(localStorage.getItem('xcall_manual') || 'null'); } catch (e) { return null; }
  }

  function registerManual(cfg) {
    if (!cfg.extension || !cfg.password || !cfg.domain || !cfg.ws) {
      setRegState('Failed', 'fill extension, password, domain, and WSS server');
      setStatus('Registration failed', 'err');
      return;
    }
    user.mode = 'manual';
    saveManual(cfg);
    show($('authNotice'), false);
    show($('manualForm'), false);
    registerWith(cfg);
  }

  // ------------------------------------------------------------------ //
  // call controls
  // ------------------------------------------------------------------ //
  function placeCall(number) {
    if (!user.ua || !user.registered) { log('Not registered'); return; }
    var target = 'sip:' + number + '@' + user.cfg.domain;
    log('Calling ' + number + ' …');

    session = user.ua.invite(target, {
      media: { constraints: { audio: true, video: false } }
    });

    session.on('accepted', function () {
      setStatus('In call', 'ok');
      setCaller(number, number);
      startTicker();
      show($('hangupBtn'), true);
      log('Call accepted');
    });
    session.on('terminated', function () {
      onCallEnded('Call ended');
    });
    session.on('failed', function (e) {
      onCallEnded('Call failed: ' + (e && e.cause ? e.cause : 'unknown'));
    });
    session.on('progress', function () { setStatus('Ringing…', 'ring'); });
  }

  function onCallEnded(msg) {
    stopTicker();
    show($('hangupBtn'), false);
    setStatus('Ready — ' + (user.cfg ? user.cfg.extension : ''), 'ok');
    setCaller('—', '—');
    if (msg) log(msg);
    session = null;
    muted = false; onHold = false;
    $('muteBtn').classList.remove('active');
    $('holdBtn').classList.remove('active');
  }

  function hangUp() {
    if (session) {
      session.terminate();
      onCallEnded('Call ended');
    }
  }

  function toggleMute() {
    muted = !muted;
    if (session) {
      try {
        var streams = session.mediaHandler.getLocalStreams && session.mediaHandler.getLocalStreams();
        if (streams) streams.forEach(function (s) {
          s.getAudioTracks().forEach(function (t) { t.enabled = !muted; });
        });
      } catch (e) { /* older API */ }
    }
    $('muteBtn').classList.toggle('active', muted);
    log(muted ? 'Muted' : 'Unmuted');
  }

  function toggleHold() {
    onHold = !onHold;
    if (session) {
      if (onHold) { session.hold(); } else { session.unhold(); }
    }
    $('holdBtn').classList.toggle('active', onHold);
    log(onHold ? 'On hold' : 'Resumed');
  }
  // ------------------------------------------------------------------ //
  // ui wiring
  // ------------------------------------------------------------------ //
  function wire() {
    var keys = document.querySelectorAll('.key');
    keys.forEach(function (btn) {
      btn.addEventListener('click', function () {
        var input = $('numberInput');
        input.value += btn.getAttribute('data-d');
        input.focus();
        if (session) { sendDTMF(btn.getAttribute('data-d')); }
      });
    });

    $('numberInput').addEventListener('keydown', function (e) {
      if (e.key === 'Enter') {
        e.preventDefault();
        placeCall(this.value);
      }
    });
    $('callBtn').addEventListener('click', function () { placeCall($('numberInput').value); });
    $('hangupBtn').addEventListener('click', hangUp);
    $('muteBtn').addEventListener('click', toggleMute);
    $('holdBtn').addEventListener('click', toggleHold);

    // registrar controls
    $('retryBtn').addEventListener('click', function () {
      if (user.mode === 'manual' && user.cfg) {
        registerWith(user.cfg);
      } else {
        loadPortalConfig();
      }
    });

    $('manualToggle').addEventListener('click', function () {
      var f = $('manualForm');
      var on = f.classList.contains('hidden');
      show(f, on);
      if (on && !user.cfg) {
        var m = loadManual();
        if (m) {
          $('mExt').value = m.extension || m.username || '';
          $('mPass').value = m.password || '';
          $('mDomain').value = m.domain || '';
          $('mWs').value = m.ws || '';
        }
      }
    });

    $('manualForm').addEventListener('submit', function (e) {
      e.preventDefault();
      registerManual(manualValues());
    });

    $('mUsePortal').addEventListener('click', function () {
      show($('manualForm'), false);
      try { localStorage.removeItem('xcall_manual'); } catch (e) { /* ignore */ }
      loadPortalConfig();
    });

    $('authManual').addEventListener('click', function () {
      $('manualToggle').click();
    });
  }

  function sendDTMF(digit) {
    if (session && session.dtmf) { session.dtmf(digit); }
  }

  // ------------------------------------------------------------------ //
  // boot
  // ------------------------------------------------------------------ //
  function boot() {
    wire();
    loadPortalConfig();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
