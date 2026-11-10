require "../../../src/app/app"
require "../../../src/plugins/builtins/nspanel"

app = CrystKit::App.new
app.plugin(CrystKit::Plugins::NSPanel.new({
  "hover" => CrystKit::Plugins::NSPanel::PanelOptions.new(
    hover_activate: true,
    floating: true,
    level: CrystKit::Plugins::NSPanel::Level::Floating,
    hides_on_deactivate: false,
    works_when_modal: true,
    movable_by_background: true,
    collection_behavior: CrystKit::Plugins::NSPanel::Behavior::FullScreenAuxiliary |
                         CrystKit::Plugins::NSPanel::Behavior::CanJoinAllSpaces,
  ),
}))

app.command "app.hide_panel" do
  panel = CrystKit::Plugins::NSPanel.find("hover")
  if p = panel
    p.hide
    {"hidden" => true}
  else
    {"error" => "panel not found"}
  end
end

app.window(
  title: "Mini Panel",
  label: "hover",
  width: 300,
  height: 200,
  html: <<-HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Mini Panel</title>
    <style>
      body {
        margin: 0; padding: 10px;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        background-color: rgba(240, 240, 240, 0.95);
        color: #333; user-select: none;
      }
      .panel-content { text-align: center; }
      h2 { margin-top: 0; color: #555; font-size: 16px; }
      .info { margin: 15px 0; font-size: 14px; color: #666; }
      .controls { margin-top: 5px; }
      button {
        background-color: #007aff; color: white; border: none;
        padding: 8px 16px; border-radius: 6px; font-size: 14px;
        cursor: pointer;
      }
      button:hover { background-color: #0051d5; }
      button:active { background-color: #0041a8; }
      .status { margin-top: 15px; font-size: 12px; color: #888; }
      .drag-region {
        height: 30px; background-color: rgba(200,200,200,0.5);
        color: #777; margin-bottom: 10px; border-radius: 10px;
        cursor: move; text-align: center; font-size: 12px;
        line-height: 30px; user-select: none;
      }
    </style>
    </head>
    <body>
      <div class="drag-region" style="-webkit-app-region: drag">drag region</div>
      <div class="panel-content">
        <h2>Mini Panel</h2>
        <textarea autofocus>Hover to activate panel</textarea>
        <div class="controls">
          <button onclick="hidePanel()">Hide Panel</button>
        </div>
        <div class="status" id="status">
          Hover or click to test key window behavior
        </div>
      </div>
      <script>
        const ipc = window.__CRYSTKIT_IPC__;
        async function hidePanel() {
          ipc.invoke('app.hide_panel');
        }
        document.body.addEventListener('mouseenter', () => {
          document.getElementById('status').textContent = 'Mouse inside panel';
        });
        document.body.addEventListener('mouseleave', () => {
          document.getElementById('status').textContent = 'Mouse outside panel';
        });
      </script>
    </body></html>
  HTML
)

app.run
