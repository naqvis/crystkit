require "../../../src/app/app"
require "../../../src/plugins/builtins/nspanel"

app = CrystKit::App.new
app.plugin(CrystKit::Plugins::NSPanel.new({
  "tracker" => CrystKit::Plugins::NSPanel::PanelOptions.new(
    floating: true,
    level: CrystKit::Plugins::NSPanel::Level::Floating,
    accepts_mouse_moved_events: true,
  ),
}))

app.command "app.set_alpha", Float64 do |alpha|
  panel = CrystKit::Plugins::NSPanel.find("tracker")
  if p = panel
    p.alpha = alpha
    {"success" => true}
  else
    {"success" => false}
  end
end

app.window(
  title: "Mouse Tracker",
  label: "tracker",
  width: 300,
  height: 200,
  html: <<-HTML
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"><title>Mouse Tracker</title>
    <style>
      body { font-family: system-ui; margin: 0; padding: 16px;
             background: rgba(30,30,46,0.95); color: #cdd6f4; }
      h2 { margin: 0 0 8px 0; font-size: 14px; color: #89b4fa; }
      .coord { font-size: 12px; opacity: 0.7; margin-bottom: 4px; }
      .dot { position: fixed; width: 8px; height: 8px; border-radius: 50%;
             background: #f38ba8; pointer-events: none; transform: translate(-4px, -4px); }
      .crosshair { position: fixed; pointer-events: none; }
      .crosshair::before, .crosshair::after {
        content: ''; position: absolute; background: rgba(243,139,168,0.3);
      }
      .crosshair::before { width: 100%; height: 1px; top: 0; left: 0; }
      .crosshair::after { width: 1px; height: 100%; top: 0; left: 0; }
    </style></head>
    <body>
      <h2>Mouse Tracker</h2>
      <div class="coord">X: <span id="mx">0</span> &nbsp; Y: <span id="my">0</span></div>
      <div class="dot" id="dot"></div>
      <div class="crosshair" id="crosshair" style="left:200px;top:100px;width:0;height:0;"></div>
      <script>
        document.addEventListener('mousemove', e => {
          document.getElementById('mx').textContent = e.clientX;
          document.getElementById('my').textContent = e.clientY;
          const d = document.getElementById('dot');
          d.style.left = e.clientX + 'px';
          d.style.top = e.clientY + 'px';
          const c = document.getElementById('crosshair');
          c.style.left = e.clientX + 'px';
          c.style.top = e.clientY + 'px';
        });
      </script>
    </body></html>
  HTML
)

app.run
