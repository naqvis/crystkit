require "../../src/app/app"
require "../../src/plugins/builtins"

app = CrystKit::App.new
app.grant("context_menu:custom")
# app.plugin(CrystKit::Plugins::ContextMenu.new)

# cm = app.find_plugin(CrystKit::Plugins::ContextMenu).context_menu
cm = CrystKit::Features::ContextMenu.new

cm.on_link do |b|
  _url = b.context.link_url.to_s
  b.add("Open in Browser", "open-link")
  b.add("Copy Link URL", "copy-link")
  b.add_separator
  b.add("Bookmark This Page", "bookmark")
end

cm.on_image do |b|
  b.add("Save Image As...", "save-image")
  b.add("Copy Image", "copy-image")
end

cm.on_text_selection do |b|
  b.add("Search for \"#{b.context.selection}\"", "search-selection")
  b.add_separator
end

cm.on_editable do |b|
  b.add_checkbox("Spell Check", "spell-check", checked: true)
  b.add_submenu("Insert") do |sub|
    sub.add("Emoji", "insert-emoji")
    sub.add("Date", "insert-date")
    sub.add("Signature", "insert-signature")
  end
end

cm.on_default do |b|
  b.add("Custom Action", "custom-action")
end

app.window(
  title: "CrystKit -- Context Menu Demo",
  width: 700,
  height: 500,
  html: <<-HTML
    <!DOCTYPE html>
    <html><head><meta charset="UTF-8"><title>Context Menu Demo</title>
    <style>
      body { font-family: system-ui; max-width: 600px; margin: 40px auto; padding: 0 20px; }
      .section { margin: 16px 0; padding: 16px; border: 1px solid #ddd; border-radius: 4px; }
      .section h3 { margin: 0 0 8px 0; }
      pre { background: #f4f4f4; padding: 12px; border-radius: 4px; min-height: 24px; }
      img { max-width: 300px; border: 1px solid #ccc; border-radius: 4px; margin: 8px 0; }
      textarea { width: 100%; height: 60px; }
    </style></head>
    <body>
      <h1>Context Menu Demo</h1>
      <p>Right-click in different areas to see context-sensitive menus.</p>

      <div class="section" id="text-section">
        <h3>Text Area (Editable)</h3>
        <textarea placeholder="Right-click here for editable-area menu..."></textarea>
      </div>

      <div class="section">
        <h3>Selected Text</h3>
        <p>Select some text in this paragraph and right-click it. Try selecting "right-click" in this sentence and then right-clicking.</p>
      </div>

      <div class="section">
        <h3>Link</h3>
        <a href="#" id="demo-link">Right-click this link</a>
      </div>

      <div class="section">
        <h3>General Area</h3>
        <p>Right-click anywhere else for the default menu.</p>
      </div>

      <h3>Output</h3>
      <pre id="output">Ready</pre>

      <script>
        var ipc = window.__CRYSTKIT_IPC__ || window.CrystKit;
        var out = document.getElementById('output');

        ipc.listen('contextmenu.action', function(payload) {
          out.textContent = 'Custom action: ' + payload.item_id;
        });
      </script>
    </body></html>
  HTML
)

app.run
