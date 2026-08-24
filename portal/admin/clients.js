/* XCall Admin — clients CRM logic. */
(function () {
  'use strict';

  var modal = document.getElementById('modal');
  var form  = document.getElementById('clientForm');
  var tbody = document.getElementById('clientRows');

  function statusBadge(s) {
    var cls = s === 'active' ? 'xcall-badge-ok' : (s === 'lead' ? 'xcall-badge-lead' : 'xcall-badge-off');
    return '<span class="' + cls + '">' + (s || 'active') + '</span>';
  }

  function render(clients) {
    if (!clients.length) {
      tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;color:#94a3b8;padding:24px">No clients yet — click "+ Add client".</td></tr>';
      return;
    }
    tbody.innerHTML = clients.map(function (c) {
      return '<tr>' +
        '<td><strong>' + esc(c.client_name) + '</strong></td>' +
        '<td>' + esc(c.client_phone) + '</td>' +
        '<td>' + esc(c.client_email) + '</td>' +
        '<td>' + esc(c.client_company) + '</td>' +
        '<td>' + statusBadge(c.client_status) + '</td>' +
        '<td>' +
          '<button class="xcall-btn xcall-btn-outline" data-edit="' + esc(c.client_uuid) + '">Edit</button> ' +
          '<button class="xcall-btn xcall-btn-danger" data-del="' + esc(c.client_uuid) + '">Delete</button>' +
        '</td></tr>';
    }).join('');
  }

  function esc(s) {
    var d = document.createElement('div');
    d.textContent = s == null ? '' : String(s);
    return d.innerHTML;
  }

  function load() {
    return fetch('admin_api.php?action=clients_list')
      .then(function (r) { return r.json(); })
      .then(function (res) { render(res.clients || []); });
  }

  function openModal(client) {
    document.getElementById('modalTitle').textContent = client ? 'Edit client' : 'Add client';
    form.reset();
    form.client_uuid.value = client ? client.client_uuid : '';
    form.client_name.value = client ? client.client_name : '';
    form.client_phone.value = client ? client.client_phone : '';
    form.client_email.value = client ? client.client_email : '';
    form.client_company.value = client ? client.client_company : '';
    form.client_notes.value = client ? (client.client_notes || '') : '';
    form.client_status.value = client ? (client.client_status || 'active') : 'active';
    modal.classList.add('show');
  }

  document.getElementById('addBtn').addEventListener('click', function () { openModal(null); });
  document.getElementById('cancelBtn').addEventListener('click', function () { modal.classList.remove('show'); });
  modal.addEventListener('click', function (e) { if (e.target === modal) modal.classList.remove('show'); });

  form.addEventListener('submit', function (e) {
    e.preventDefault();
    var data = {};
    new FormData(form).forEach(function (v, k) { data[k] = v; });
    fetch('admin_api.php?action=client_save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data)
    })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (res.error) throw new Error(res.error);
        modal.classList.remove('show');
        toast('Client saved');
        load();
      })
      .catch(function (err) { toast('Save failed: ' + err.message, 'err'); });
  });

  tbody.addEventListener('click', function (e) {
    var editBtn = e.target.closest('[data-edit]');
    var delBtn  = e.target.closest('[data-del]');
    if (editBtn) {
      fetch('admin_api.php?action=clients_list')
        .then(function (r) { return r.json(); })
        .then(function (res) {
          var c = (res.clients || []).filter(function (x) { return x.client_uuid === editBtn.dataset.edit; })[0];
          if (c) openModal(c);
        });
      return;
    }
    if (delBtn) {
      if (!confirm('Delete this client?')) return;
      fetch('admin_api.php?action=client_delete&client_uuid=' + encodeURIComponent(delBtn.dataset.del), { method: 'POST' })
        .then(function (r) { return r.json(); })
        .then(function (res) {
          if (res.error) throw new Error(res.error);
          toast('Client deleted');
          load();
        })
        .catch(function (err) { toast('Delete failed: ' + err.message, 'err'); });
    }
  });

  load();
})();
