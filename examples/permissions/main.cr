require "../../src/app/app"
require "../../src/plugins/builtins"
require "../../src/features/message_dialog"

app = CrystKit::App.new
app.plugin(CrystKit::Plugins::Permissions.new)

html_content = <<-HTML
  <!DOCTYPE html>
  <html><head><meta charset="UTF-8"><title>Permissions Demo</title>
  <style>
    body { font-family: system-ui; max-width: 700px; margin: 40px auto; padding: 0 20px; }
    button { margin: 4px; padding: 8px 16px; cursor: pointer; }
    pre { background: #f4f4f4; padding: 12px; border-radius: 4px; min-height: 40px; }
    video { width: 100%; max-width: 400px; border: 1px solid #ccc; border-radius: 4px; margin: 8px 0; }
    .section { margin: 16px 0; padding: 12px; border: 1px solid #ddd; border-radius: 4px; }
    .section h3 { margin: 0 0 8px 0; }
  </style></head>
  <body>
    <h1>Permissions Demo</h1>
    <p>Click a "Request" button — a native macOS dialog will appear. If Allow is selected, the demo will try to access the device via getUserMedia.</p>

    <div class="section">
      <h3>Request Permissions</h3>
      <div class="controls">
        <button id="req-camera">Request Camera</button>
        <button id="req-mic">Request Microphone</button>
        <button id="req-geo">Request Geolocation</button>
      </div>
    </div>

    <div class="section">
      <h3>Default Policies</h3>
      <div class="controls">
        <button id="grant-camera">Grant Camera</button>
        <button id="deny-camera">Deny Camera</button>
        <button id="grant-geo">Grant Geolocation</button>
        <button id="deny-geo">Deny Geolocation</button>
        <button id="reset">Reset All to Prompt</button>
      </div>
    </div>

    <div class="section">
      <h3>Status</h3>
      <div class="controls">
        <button id="status-camera">Check Camera Default</button>
        <button id="status-geo">Check Geolocation Default</button>
      </div>
    </div>

    <h3>Output</h3>
    <pre id="output">Ready</pre>
    <video id="cam" autoplay playsinline muted style="display:none"></video>

    <script>
      const ipc = window.__CRYSTKIT_IPC__;
      const out = document.getElementById('output');
      const cam = document.getElementById('cam');

      async function call(cmd, arg) {
        try {
          const r = await ipc.invoke(cmd, arg || {});
          out.textContent = JSON.stringify(r, null, 2);
          return r;
        } catch(e) {
          out.textContent = 'Error: ' + e.message;
        }
      }

      async function requestAndUse(type) {
        const origin = window.location.origin;
        const r = await call('permissions.request_demo', [type, origin]);
        if (r && r.state === 'Granted') {
          try {
            const constraints = type === 'Camera' ? { video: true } :
                                type === 'Microphone' ? { audio: true } : { video: true };
            if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
              const stream = await navigator.mediaDevices.getUserMedia(constraints);
              cam.style.display = 'block';
              cam.srcObject = stream;
              out.textContent = JSON.stringify({ state: 'Granted', stream: 'active' }, null, 2);
            } else {
              out.textContent = JSON.stringify({ state: 'Granted', note: 'navigator.mediaDevices undefined' }, null, 2);
            }
          } catch(e) {
            out.textContent = 'getUserMedia error: ' + e.message;
          }
        } else if (r && r.state === 'Denied') {
          cam.style.display = 'none';
          if (cam.srcObject) { cam.srcObject.getTracks().forEach(t => t.stop()); cam.srcObject = null; }
        }
      }

      document.getElementById('req-camera').onclick = () => requestAndUse('Camera');
      document.getElementById('req-mic').onclick    = () => requestAndUse('Microphone');
      document.getElementById('req-geo').onclick    = () => requestAndUse('Geolocation');

      document.getElementById('grant-camera').onclick = () => call('permissions.set_default', ['Camera', 'Granted']);
      document.getElementById('deny-camera').onclick  = () => call('permissions.set_default', ['Camera', 'Denied']);
      document.getElementById('grant-geo').onclick    = () => call('permissions.set_default', ['Geolocation', 'Granted']);
      document.getElementById('deny-geo').onclick     = () => call('permissions.set_default', ['Geolocation', 'Denied']);
      document.getElementById('reset').onclick        = () => call('permissions.reset');

      document.getElementById('status-camera').onclick = () => call('permissions.status', ['Camera', null]);
      document.getElementById('status-geo').onclick    = () => call('permissions.status', ['Geolocation', null]);
    </script>
  </body></html>
HTML

perms_plugin = app.find_plugin?(CrystKit::Plugins::Permissions)
if perms_plugin
  dialog = CrystKit::Features::MessageDialog.new
  decided = {} of String => Bool
  perms_plugin.permissions_manager.on_request do |req|
    key = "#{req.origin}::#{req.type}"
    next if decided[key]?
    allowed = dialog.confirm(
      CrystKit::Features::ConfirmOptions.new(
        title: "Permission Request",
        message: "#{req.type} from '#{app.config.name}' requests permission.",
      ),
    )
    req.state = allowed ? CrystKit::Features::PermissionState::Granted : CrystKit::Features::PermissionState::Denied
    decided[key] = true
  end

  app.command "permissions.request_demo", String, String do |type_str, origin_str|
    ptype = CrystKit::Features::PermissionType.parse?(type_str)
    next {"error" => "Unknown permission type: #{type_str}"} unless ptype
    origin = URI.parse(origin_str)
    pm = perms_plugin.permissions_manager
    state = pm.handle_request(ptype, origin)
    pm.persist(origin, ptype, state)
    {"type" => type_str, "state" => state.to_s}
  end
end

app.window(
  title: "CrystKit — Permissions Demo",
  width: 800,
  height: 600,
  html: html_content,
  debug: true,
)

app.run
