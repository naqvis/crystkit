require "../../src/app/app"
require "../../src/plugins/builtins"

app = CrystKit::App.new

app.grant("toolbar:manage", "dialog:open", "window:manage")

app.plugin(CrystKit::Plugins::Toolbar.new)
app.plugin(CrystKit::Plugins::Dialog.new)

app.command("app.quit") { app.quit }

main_window = app.window(
  title: "JS-Driven Toolbar",
  label: "main",
  width: 700,
  height: 500,
  html: <<-HTML
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <title>JS-Driven Toolbar</title>
      <style>
        body { font-family: system-ui; max-width: 640px; margin: 40px auto; padding: 0 20px; }
        button { margin: 4px; padding: 8px 16px; cursor: pointer; }
        #log { margin-top: 16px; padding: 12px; background: #f4f4f4; border-radius: 4px; min-height: 100px; white-space: pre-wrap; }
      </style>
    </head>
    <body>
      <h1>JS-Driven Toolbar</h1>
      <p>Toolbar is built from JavaScript, not Crystal. All 4 item types shown.</p>
      <div>
        <button id="addButton">Add "New"</button>
        <button id="addToggle">Add Toggle</button>
        <button id="addColor">Add Color</button>
        <button id="toggleVisibility">Hide Toolbar</button>
        <button id="clearToolbar">Clear All</button>
        <button id="listItems">List Items</button>
      </div>
      <div id="status" style="margin-top: 12px; padding: 8px; background: #e8f4e8; border-radius: 4px;">Ready. Toolbar items added on load.</div>
      <div id="log">Toolbar built automatically on page load via JS IPC calls.</div>

      <script>
        document.addEventListener('DOMContentLoaded', function () {
          const ipc = window.__CRYSTKIT_IPC__;
          const logEl = document.getElementById('log');
          const statusEl = document.getElementById('status');
          const log = function (msg) { logEl.textContent += msg + "\\n"; };
          const status = function (msg) { statusEl.textContent = msg; };

          if (!ipc) {
            log('ERROR: __CRYSTKIT_IPC__ not found');
            return;
          }

          function handleToolbarClick(itemId) {
            status('Clicked: ' + itemId);
            if (itemId === 'new') {
              ipc.invoke('dialog.message', {
                title: 'New File',
                message: 'New file created!',
                kind: 'info'
              }).catch(function (e) { log('dialog.message FAILED: ' + e.message); });
            } else if (itemId === 'save') {
              status('File saved successfully.');
            } else if (itemId === 'delete') {
              ipc.invoke('dialog.message', {
                title: 'Delete',
                message: 'Are you sure?',
                kind: 'warning'
              }).catch(function (e) { log('dialog.message FAILED: ' + e.message); });
            } else if (itemId === 'quit') {
              ipc.invoke('app.quit').catch(function (e) { log('app.quit FAILED: ' + e.message); });
            }
          }

          ipc.listen('toolbar.click', function (p) {
            log('toolbar.click: ' + JSON.stringify(p));
            handleToolbarClick(p.item_id);
          });

          ipc.listen('toolbar.dropdown_selected', function (p) {
            log('toolbar.dropdown_selected: ' + JSON.stringify(p));
            status('Dropdown selected: ' + p.item_id);
          });

          var hidden = false;
          var boldState = false;

          function buildToolbar() {
            return ipc.invoke('toolbar.add_item', ['new', 'New', 'doc'])
              .then(function () { return ipc.invoke('toolbar.add_item', ['save', 'Save', 'square.and.arrow.down']); })
              .then(function () { return ipc.invoke('toolbar.add_separator'); })
              .then(function () { return ipc.invoke('toolbar.add_item', ['delete', 'Delete', 'trash']); })
              .then(function () { return ipc.invoke('toolbar.add_separator'); })
              .then(function () { return ipc.invoke('toolbar.add_item', ['quit', 'Quit', 'xmark']); })
              .then(function () { return ipc.invoke('toolbar.add_separator'); })
              .then(function () { return ipc.invoke('toolbar.add_toggle', ['bold', 'Bold', 'bold', true]); })
              .then(function () { return ipc.invoke('toolbar.add_dropdown', ['size', 'Size', null, ['12','14','16','18','24'], 2]); })
              .then(function () { return ipc.invoke('toolbar.add_separator'); })
              .then(function () { return ipc.invoke('toolbar.add_color', ['fgcolor', 'Color', '#FF0000']); })
              .then(function () { return ipc.invoke('toolbar.show'); });
          }

          buildToolbar()
            .then(function () { log('Toolbar built OK — includes toggle (Bold), dropdown (Size), and color picker'); })
            .catch(function (e) { log('toolbar FAILED: ' + e.message + ' (' + e.code + ')'); });

          document.getElementById('addButton').onclick = function () {
            var count = Date.now();
            ipc.invoke('toolbar.add_item', ['item-' + count, 'Item ' + count, 'plus.circle'])
              .then(function () { log('Added item-' + count); })
              .catch(function (e) { log('add_item FAILED: ' + e.message); });
          };

          document.getElementById('addToggle').onclick = function () {
            boldState = !boldState;
            ipc.invoke('toolbar.add_toggle', ['bold-' + Date.now(), 'Toggle', null, boldState])
              .then(function () { log('Added toggle (state=' + boldState + ')'); })
              .catch(function (e) { log('add_toggle FAILED: ' + e.message); });
          };

          document.getElementById('addColor').onclick = function () {
            var hex = '#' + Math.floor(Math.random()*0xFFFFFF).toString(16).padStart(6, '0');
            ipc.invoke('toolbar.add_color', ['color-' + Date.now(), hex, hex])
              .then(function () { log('Added color: ' + hex); })
              .catch(function (e) { log('add_color FAILED: ' + e.message); });
          };

          document.getElementById('toggleVisibility').onclick = function () {
            hidden = !hidden;
            var cmd = hidden ? 'toolbar.hide' : 'toolbar.show';
            this.textContent = hidden ? 'Show Toolbar' : 'Hide Toolbar';
            ipc.invoke(cmd).catch(function (e) { log(cmd + ' FAILED: ' + e.message); });
          };

          document.getElementById('clearToolbar').onclick = function () {
            ipc.invoke('toolbar.clear')
              .then(function () { log('Toolbar cleared'); })
              .catch(function (e) { log('toolbar.clear FAILED: ' + e.message); });
          };

          document.getElementById('listItems').onclick = function () {
            ipc.invoke('toolbar.items')
              .then(function (r) { log('Items: ' + JSON.stringify(r.items)); })
              .catch(function (e) { log('toolbar.items FAILED: ' + e.message); });
          };
        });
      </script>
    </body>
    </html>
  HTML
)

if tb_plugin = app.find_plugin?(CrystKit::Plugins::Toolbar)
  tb = tb_plugin.toolbar
  tb.install(main_window)
end

app.run
