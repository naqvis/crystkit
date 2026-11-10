require "../../src/app/app"
require "../../src/plugins/builtins"
require "../../src/features/biometric"

app = CrystKit::App.new
app.grant("biometric:authenticate")
app.plugin(CrystKit::Plugins::Biometric.new)

app.window(
  title: "CrystKit -- Biometric Auth Demo",
  width: 700,
  height: 500,
  html: <<-HTML
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"><title>Biometric Auth Demo</title>
    <style>
      body { font-family: system-ui; max-width: 600px; margin: 40px auto; padding: 0 20px; }
      button { margin: 4px; padding: 10px 20px; font-size: 14px; cursor: pointer; }
      pre { background: #f4f4f4; padding: 12px; border-radius: 4px; min-height: 40px; }
      #status { margin-top: 12px; padding: 12px; border-radius: 4px; }
      .success { background: #d4edda; color: #155724; }
      .failure { background: #f8d7da; color: #721c24; }
      .info { background: #d1ecf1; color: #0c5460; }
    </style></head>
    <body>
      <h1>Biometric Authentication Demo</h1>

      <div>
        <button id="check">Check Availability</button>
        <button id="auth">Authenticate</button>
      </div>

      <div>Last action: <span id="action">none</span></div>
      <pre id="output">Click a button to start.</pre>

      <div id="status"></div>

      <script>
        const ipc = window.__CRYSTKIT_IPC__;
        const out = document.getElementById('output');
        const status = document.getElementById('status');
        const action = document.getElementById('action');

        function show(type, msg) {
          status.className = type;
          status.textContent = msg;
        }

        document.getElementById('check').onclick = async () => {
          action.textContent = 'biometric.available';
          out.textContent = 'Checking...';
          try {
            const r = await ipc.invoke('biometric.available');
            out.textContent = JSON.stringify(r, null, 2);
            if (r.available) {
              const modality = r.modality || 'unknown';
              const reason = r.reason_supported ? 'prompt reason supported' : 'prompt reason controlled by OS';
              show('info', 'Biometric authentication is available (' + modality + ', ' + reason + ').');
            } else {
              show('info', 'No biometric hardware detected on this system.');
            }
          } catch(e) {
            out.textContent = 'Error: ' + e.message;
            show('failure', 'IPC call failed.');
          }
        };

        document.getElementById('auth').onclick = async () => {
          action.textContent = 'biometric.authenticate';
          out.textContent = 'Waiting for biometric prompt...';
          show('info', 'Please authenticate using your biometric sensor.');
          try {
            const r = await ipc.invoke('biometric.authenticate', 'Unlock demo app');
            out.textContent = JSON.stringify(r, null, 2);
            if (r.success) {
              show('success', 'Authentication successful!');
            } else {
              show('failure', r.error || 'Authentication failed.');
            }
          } catch(e) {
            out.textContent = 'Error: ' + e.message;
            show('failure', 'IPC call failed.');
          }
        };
      </script>
    </body></html>
  HTML
)

app.run
