/* XCall Admin Panel — shared toast helper. */
function toast(msg, kind) {
  var el = document.createElement('div');
  el.className = 'xcall-toast ' + (kind || 'ok');
  el.textContent = msg;
  document.body.appendChild(el);
  requestAnimationFrame(function () { el.classList.add('show'); });
  setTimeout(function () {
    el.classList.remove('show');
    setTimeout(function () { el.remove(); }, 300);
  }, 2600);
}
