require "../../src/app/app"
require "../../src/plugins/builtins"

# Minimal example: menubar and tray menu are built entirely from JavaScript
# via the built-in MenuBar and Tray plugins.

config = CrystKit::AppConfig.new(
  name: "JS Menus",
  frontend_dist: "#{__DIR__}/assets",
)

app = CrystKit::App.new(config)

# Grant the capabilities the JS frontend needs to drive the plugins.
app.grant("menu:manage", "tray:manage", "dialog:open", "window:manage")

app.plugin(CrystKit::Plugins::MenuBar.new)
app.plugin(CrystKit::Plugins::Tray.new)
app.plugin(CrystKit::Plugins::Dialog.new)

# Typed Crystal command invoked from JS to exit the application.
app.command("app.quit") { app.quit }

# Tray icon served from VFS (frontend_dist = assets/), referenced by VFS path

app.window(
  title: "JS-Driven Menus",
  label: "main",
  width: 700,
  height: 500,
  html: <<-HTML
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <title>JS-Driven Menus</title>
      <style>
        body { font-family: system-ui; max-width: 640px; margin: 40px auto; padding: 0 20px; }
        button { margin: 4px; padding: 8px 16px; cursor: pointer; }
        #log { margin-top: 16px; padding: 12px; background: #f4f4f4; border-radius: 4px; min-height: 100px; white-space: pre-wrap; }
      </style>
    </head>
    <body>
      <h1>JS-Driven Menus</h1>
      <p>Menus are built from JavaScript, not Crystal.</p>
      <button id="updateTrayMenu">Update Tray Menu</button>
      <div id="status" style="margin-top: 12px; padding: 8px; background: #e8f4e8; border-radius: 4px;">Waiting for menu action…</div>
      <div id="log">Menus are built automatically on page load via JS IPC calls.</div>

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

          function showAbout() {
            ipc.invoke('dialog.message', {
              title: 'About JS Menus',
              message: 'This example builds native menus entirely from JavaScript using CrystKit plugins.',
              kind: 'info'
            }).catch(function (e) { log('dialog.message FAILED: ' + e.message); });
          }

          function quitApp() {
            ipc.invoke('app.quit')
              .then(function () { status('Quitting…'); })
              .catch(function (e) { log('app.quit FAILED: ' + e.message); });
          }

          function handleMenuClick(itemId) {
            status('Last action: ' + itemId);
            if (itemId === 'about') {
              showAbout();
            } else if (itemId === 'quit') {
              quitApp();
            } else if (itemId === 'greet') {
              status('Hello from the JS-driven menu!');
            } else if (itemId === 'toggle') {
              status('Toggle item clicked (checkbox state handled by OS)');
            }
          }

          ipc.listen('menu.click', function (p) {
            log('menu.click: ' + JSON.stringify(p));
            handleMenuClick(p.item_id);
          });

          ipc.listen('tray.click', function (p) {
            log('tray.click: ' + JSON.stringify(p));
            status('Tray icon clicked: ' + p.button);
          });

          ipc.listen('tray.menu_click', function (p) {
            log('tray.menu_click: ' + JSON.stringify(p));
            if (p.item_id === 'show') {
              ipc.invoke('window.show', 'main').catch(function (e) { log('window.show FAILED: ' + e.message); });
            } else if (p.item_id === 'preferences') {
              showAbout();
            } else if (p.item_id === 'quit') {
              quitApp();
            } else {
              handleMenuClick(p.item_id);
            }
          });

          const menuBarJson = [
            {
              label: "App",
              items: [
                { id: "about", label: "About JS Menus" },
                { type: "separator" },
                { id: "quit", label: "Quit", accelerator: "Cmd+Q" }
              ]
            },
            {
              label: "Actions",
              items: [
                { id: "greet", label: "Greet" },
                { id: "toggle", label: "Toggle", checked: true, type: "checkbox" }
              ]
            }
          ];

          const trayMenuJson = [
            { id: "show", label: "Show Window" },
            { type: "separator" },
            { id: "preferences", label: "Preferences" },
            { type: "separator" },
            { id: "quit", label: "Quit" }
          ];

          function init() {
            ipc.invoke('menu.build', menuBarJson)
              .then(function () { log('menu.build OK'); })
              .catch(function (e) { log('menu.build FAILED: ' + e.message + ' (' + e.code + ')'); })
              .then(function () {
                return ipc.invoke('tray.create', {
                  icon: "tray_icon.png",
                  tooltip: "JS-Driven Tray",
                  menu: trayMenuJson
                });
              })
              .then(function () { log('tray.create OK'); })
              .catch(function (e) { log('tray.create FAILED: ' + e.message + ' (' + e.code + ')'); });
          }

          document.getElementById('updateTrayMenu').onclick = function () {
            ipc.invoke('tray.set_menu', [
              { id: "show", label: "Show Window" },
              { type: "separator" },
              { id: "quit", label: "Quit" }
            ])
              .then(function () { log('tray.set_menu OK'); })
              .catch(function (e) { log('tray.set_menu FAILED: ' + e.message + ' (' + e.code + ')'); });
          };

          init();
        });
      </script>
    </body>
    </html>
  HTML
)

app.run
