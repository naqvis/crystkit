require "../../../src/app/app"
require "../../../src/plugins/builtins/nspanel"

app = CrystKit::App.new
app.plugin(CrystKit::Plugins::NSPanel.new({
  "palette" => CrystKit::Plugins::NSPanel::PanelOptions.new(
    floating: true,
    transparent: true,
    movable_by_background: true,
    has_shadow: true,
    corner_radius: 12.0,
    collection_behavior: CrystKit::Plugins::NSPanel::Behavior::CanJoinAllSpaces,
    level: CrystKit::Plugins::NSPanel::Level::Floating,
  ),
}))

app.command "app.toggle_palette" do
  panel = CrystKit::Plugins::NSPanel.find("palette")
  if p = panel
    if p.visible?
      p.hide
      {"visible" => false}
    else
      p.show_and_make_key
      {"visible" => true}
    end
  else
    {"success" => false}
  end
end

app.window(
  title: "Tool Palette",
  label: "palette",
  width: 320,
  height: 420,
  html: <<-HTML
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"><title>Tool Palette</title>
    <style>
      body { font-family: system-ui; margin: 0; padding: 0;
             background: transparent; color: #333; }
      .drag-handle {
        -webkit-app-region: drag;
        padding: 12px 20px;
        cursor: move;
        user-select: none;
        background: rgba(0,0,0,0.08);
        border-bottom: 1px solid rgba(0,0,0,0.06);
        border-radius: 12px 12px 0 0;
      }
      .drag-handle:hover {
        background: rgba(0,0,0,0.12);
      }
      .drag-handle h2 {
        font-size: 1.1rem; margin: 0; color: #555;
      }
      .tools { padding: 8px 20px 20px; }
      .tool { padding: 8px 12px; margin: 4px 0; background: rgba(255,255,255,0.85);
              border-radius: 8px; cursor: pointer; display: flex; align-items: center; gap: 10px; }
      .tool:hover { background: rgba(255,255,255,0.95); }
      .icon { width: 24px; height: 24px; border-radius: 4px;
              display: flex; align-items: center; justify-content: center; font-size: 14px; }
    </style></head>
    <body>
      <div class="drag-handle"><h2>Tools</h2></div>
      <div class="tools">
        <div class="tool"><div class="icon" style="background:#f38ba8;">✎</div> Select</div>
        <div class="tool"><div class="icon" style="background:#89b4fa;">⬜</div> Rectangle</div>
        <div class="tool"><div class="icon" style="background:#a6e3a1;">○</div> Ellipse</div>
        <div class="tool"><div class="icon" style="background:#fab387;">✏</div> Pencil</div>
        <div class="tool"><div class="icon" style="background:#cba6f7;">🅃</div> Text</div>
      </div>
    </body></html>
  HTML
)

app.run
