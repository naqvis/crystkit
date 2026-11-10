require "../../../src/app/app"
require "../../../src/plugins/builtins/nspanel"

PANEL_LEVELS = [
  {name: "Normal", level: CrystKit::Plugins::NSPanel::Level::Normal, color: "#6366f1"},
  {name: "Floating", level: CrystKit::Plugins::NSPanel::Level::Floating, color: "#8b5cf6"},
  {name: "PopUp Menu", level: CrystKit::Plugins::NSPanel::Level::PopUpMenu, color: "#a855f7"},
  {name: "Status", level: CrystKit::Plugins::NSPanel::Level::Status, color: "#f43f5e"},
  {name: "Screen Saver", level: CrystKit::Plugins::NSPanel::Level::ScreenSaver, color: "#ef4444"},
]

COUNTER = {} of String => Int32

app = CrystKit::App.new
app.plugin(CrystKit::Plugins::NSPanel.new)

app.command "app.create_level_panel", Int64 do |level|
  COUNTER["count"] = (COUNTER["count"]? || 0) + 1
  count = COUNTER["count"]
  entry = PANEL_LEVELS.find { |pl| pl[:level] == level }
  next {"success" => false, "error" => "Unknown level"} unless entry

  label = "level-#{count}"

  child = app.window(
    title: "Panel at #{entry[:name]}",
    label: label,
    width: 260,
    height: 140,
    html: <<-HTML
      <!DOCTYPE html>
      <html><head><meta charset="UTF-8"><title>#{entry[:name]}</title>
      <style>
        body { font-family: system-ui; margin: 0; padding: 16px;
               background: #{entry[:color]}; color: white; }
        h2 { margin: 0 0 8px 0; font-size: 16px; }
        p { margin: 0; font-size: 13px; opacity: 0.8; }
      </style></head>
      <body>
        <h2>#{entry[:name]} Level</h2>
        <p>Level value: #{entry[:level]}</p>
        <p>This panel stays above windows at lower levels.</p>
      </body></html>
    HTML
  )

  panel = CrystKit::Plugins::NSPanel.find(label)
  if p = panel
    p.level = entry[:level]
    p.floating = true
    p.show
  end

  child.move(80 + count * 30, 80 + count * 30)

  {"success" => true, "label" => label}
end

app.window(
  title: "Panel Levels Demo",
  label: "main",
  width: 500,
  height: 520,
  html: <<-HTML
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"><title>Panel Levels</title>
    <style>
      body { font-family: system-ui; margin: 0; padding: 20px; background: #1e1e2e; color: #cdd6f4; }
      h1 { margin: 0 0 16px 0; font-size: 20px; color: #cba6f7; }
      p { margin: 0 0 20px 0; font-size: 13px; opacity: 0.7; }
      .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
      button {
        padding: 12px; border: none; border-radius: 8px;
        font-size: 13px; font-weight: 600; cursor: pointer; color: white;
        transition: transform 0.15s, box-shadow 0.15s;
      }
      button:hover { transform: translateY(-1px); box-shadow: 0 4px 12px rgba(0,0,0,0.4); }
    </style></head>
    <body>
      <h1>Panel Levels</h1>
      <p>Each button spawns a panel at a different z-order level.</p>
      <div class="grid">
        <button onclick="create('NORMAL')" style="background:#6366f1;">Normal (0)</button>
        <button onclick="create('FLOATING')" style="background:#8b5cf6;">Floating (4)</button>
        <button onclick="create('POPUP')" style="background:#a855f7;">PopUp Menu (101)</button>
        <button onclick="create('STATUS')" style="background:#f43f5e;">Status (25)</button>
        <button onclick="create('SCREEN_SAVER')" style="background:#ef4444;">Screen Saver (1000)</button>
      </div>
      <script>
        const LEVELS = { NORMAL: 0, FLOATING: 4, POPUP: 101, STATUS: 25, SCREEN_SAVER: 1000 };
        function create(name) {
          window.__CRYSTKIT_IPC__.invoke('app.create_level_panel', LEVELS[name]);
        }
      </script>
    </body></html>
  HTML
)

app.run
