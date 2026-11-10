require "../../../src/app/app"
require "../../../src/plugins/builtins/nspanel"

STYLES = {
  "borderless"     => {mask: CrystKit::Plugins::NSPanel::Mask::Borderless, title: "Borderless", desc: "No title bar"},
  "non-activating" => {mask: CrystKit::Plugins::NSPanel::Mask::NonactivatingPanel, title: "Non-Activating", desc: "Doesn't activate app"},
}

COUNTER = {} of String => Int32

app = CrystKit::App.new
app.plugin(CrystKit::Plugins::NSPanel.new)

app.command "app.quit" do
  app.quit
end

app.command "app.close_panel", String do |label|
  app.hide_window(label)
end

app.command "app.create_style_panel", String do |style_key|
  style = STYLES[style_key]?
  unless style
    next {"success" => false, "error" => "Unknown style: #{style_key}"}
  end

  COUNTER["count"] = (COUNTER["count"]? || 0) + 1
  count = COUNTER["count"]
  label = "style-#{count}"

  app.window(
    title: style[:title],
    label: label,
    width: 280,
    height: 160,
    html: <<-HTML
      <!DOCTYPE html>
      <html><head><meta charset="UTF-8"><title>#{style[:title]}</title>
      <style>
        body { font-family: system-ui; margin: 0; padding: 16px;
               background: #1e1e2e; color: #cdd6f4; }
        h3 { margin: 0 0 4px 0; font-size: 1rem; }
        p { margin: 0; font-size: 0.8rem; opacity: 0.7; }
        .close { position: absolute; top: 6px; right: 10px;
                 background: none; border: none; color: #f38ba8;
                 font-size: 1.1rem; cursor: pointer; opacity: 0.4; }
        .close:hover { opacity: 1; }
      </style></head>
      <body>
        <button class="close" onclick="window.CrystKit.invoke('app.close_panel', '#{label}')">&times;</button>
        <h3>#{style[:title]}</h3>
        <p>#{style[:desc]}</p>
      </body></html>
    HTML
  )

  panel = CrystKit::Plugins::NSPanel.find(label)
  if p = panel
    p.style_mask = style[:mask]
    p.floating = true
    p.show
  end

  {"success" => true, "label" => label}
end

app.window(
  title: "Panel Styles Demo",
  label: "main",
  width: 400,
  height: 240,
  html: <<-HTML
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"><title>Panel Styles</title>
    <style>
      body { font-family: system-ui; margin: 0; padding: 20px; background: #1e1e2e; color: #cdd6f4; }
      h1 { margin: 0 0 16px 0; font-size: 18px; color: #cba6f7; }
      p { margin: 0 0 16px 0; font-size: 13px; opacity: 0.7; }
      .close { position: absolute; top: 8px; right: 12px;
               background: none; border: none; color: #f38ba8;
               font-size: 1.2rem; cursor: pointer; opacity: 0.4; }
      .close:hover { opacity: 1; }
      .buttons { display: flex; gap: 8px; flex-wrap: wrap; }
      button {
        padding: 10px 16px; border: none; border-radius: 8px;
        font-size: 13px; font-weight: 600; cursor: pointer; color: white;
        transition: transform 0.15s;
      }
      button:hover { transform: translateY(-1px); }
    </style></head>
    <body>
      <button class="close" onclick="window.CrystKit.invoke('app.quit')">&times;</button>
      <h1>Panel Styles</h1>
      <p>Click a button to create a panel with that style mask.</p>
      <div class="buttons">
        <button onclick="create('borderless')" style="background:#6c7086;">Borderless</button>
        <button onclick="create('non-activating')" style="background:#89b4fa;">Non-Activating</button>
      </div>
      <script>
        function create(name) {
          window.__CRYSTKIT_IPC__.invoke('app.create_style_panel', name);
        }
      </script>
    </body></html>
  HTML
)

app.run
