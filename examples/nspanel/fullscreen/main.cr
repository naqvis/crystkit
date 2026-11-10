require "../../../src/app/app"
require "../../../src/plugins/builtins/nspanel"

app = CrystKit::App.new
app.plugin(CrystKit::Plugins::NSPanel.new(
  {"overlay" => CrystKit::Plugins::NSPanel::PanelOptions.new(
    style_mask: CrystKit::Plugins::NSPanel::Mask::NonactivatingPanel,
    level: CrystKit::Plugins::NSPanel::Level::Floating,
    collection_behavior: CrystKit::Plugins::NSPanel::Behavior::FullScreenAuxiliary |
                         CrystKit::Plugins::NSPanel::Behavior::CanJoinAllSpaces,
  )},
  activation_policy: 1_i64
))

app.window(
  label: "overlay",
  title: "Overlay",
  width: 320,
  height: 180,
  html: <<-HTML
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"><title>Fullscreen Panel</title>
    <style>
      body { font-family: system-ui; margin: 0; padding: 16px;
             background: rgba(0,0,0,0.8); color: white; }
      h2 { font-size: 1rem; margin: 0; }
    </style></head>
    <body><h2>Floating Panel</h2></body></html>
  HTML
)

app.run
