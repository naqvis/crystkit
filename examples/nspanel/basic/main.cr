require "../../../src/app/app"
require "../../../src/plugins/builtins/nspanel"

app = CrystKit::App.new
app.plugin(CrystKit::Plugins::NSPanel.new)

app.command "app.quit" do
  app.quit
end

app.window(
  label: "main",
  title: "NSPanel",
  width: 400,
  height: 300,
  html: <<-HTML
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"><title>Panel</title>
    <style>
      body { font-family: system-ui; margin: 0; padding: 24px;
             background: #1e1e2e; color: #cdd6f4; }
      h1 { font-size: 1.1rem; margin: 0 0 4px 0; color: #cba6f7; }
      p  { font-size: 0.8rem; margin: 0; opacity: 0.7; }
      #close { position: absolute; top: 8px; right: 12px;
               background: none; border: none; color: #f38ba8;
               font-size: 1.2rem; cursor: pointer; opacity: 0.5; }
      #close:hover { opacity: 1; }
    </style></head>
    <body>
      <button id="close" onclick="window.CrystKit.invoke('app.quit')">&times;</button>
      <h1>NSPanel</h1>
      <p>Borderless floating panel.</p>
    </body></html>
  HTML
)

app.run
