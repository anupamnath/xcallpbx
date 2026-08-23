/* XCall web softphone — main application logic.
 *
 * Uses SIP.js (0.15.x UMD) to register a SIP over WebSocket client to
 * FreeSWITCH, letting the agent make/receive calls from the portal after
 * login. Configuration is fetched from config.php (logged-in session).
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
  var user = { registered: false };
  var session = null;        // active SIP.js InviteClientContext
  var timers = { tick: null };
  var callStart = null;
  var muted = false;
  var onHold = false;

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
  function makeUA(cfg) {
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

    ua.on('registered', function () {
      user.registered = true;
      setStatus('Ready — ' + cfg.extension, 'ok');
      log('Registered as ' + cfg.extension + ' (' + cfg.domain + ')');
      $('numberInput').disabled = false;
    });

    ua.on('unregistered', function () {
      user.registered = false;
      setStatus('Offline', 'warn');
    });

    ua.on('registrationFailed', function () {
      user.registered = false;
      setStatus('Registration failed', 'err');
      log('SIP registration failed — check password / WSS endpoint');
    });

    ua.on('invite', function (incoming) {
      session = incoming;
      setCaller(incoming.remoteIdentity.displayName, incoming.remoteIdentity.uri.user);
      setStatus('Incoming call', 'ring');
      startTicker();
      show($('hangupBtn'), true);
      log('Incoming call from ' + incoming.remoteIdentity.uri.user);
      // auto-answer is optional; uncomment to auto-accept specialist calls:
      // incoming.accept();
    });

    return ua;
  }

  function currentUA() { return user.ua; }

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
  }

  function sendDTMF(digit) {
    if (session && session.dtmf) { session.dtmf(digit); }
  }

  // ------------------------------------------------------------------ //
  // boot
  // ------------------------------------------------------------------ //
  function boot() {
    wire();
    setStatus('Loading config…');
    fetch('config.php')
      .then(function (r) {
        if (!r.ok) { throw new Error('auth required (' + r.status + ')'); }
        return r.json();
      })
      .then(function (cfg) {
        if (!cfg.username || !cfg.ws) {
          throw new Error('no SIP credentials in portal session');
        }
        user.cfg = cfg;
        log('Endpoint: ' + cfg.ws + '  Extension: ' + cfg.extension);
        user.ua = makeUA(cfg);
      })
      .catch(function (err) {
        setStatus('Not logged in', 'err');
        log('Error: ' + err.message + ' — log into the XCall portal first.');
      });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
