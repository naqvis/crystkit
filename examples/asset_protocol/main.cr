require "../../src/app/app"

# ════════════════════════════════════════════════════════════════════════════
# crystkit:// Asset Protocol Example
#
# Demonstrates serving webview assets through the custom URL scheme
# (crystkit://localhost) backed by virtualfs — with NO TCP server.
#
#   Dev:
#     crystal run examples/asset_protocol/main.cr
#
#     Assets are served from `frontend_dist` set via AppConfig.
#     In a real project, `crystkit dev` reads it from crystkit.json.
#
#   Production:
#     crystkit build && crystkit bundle
#
#     The bundler automatically emits resources/assets.vpak from
#     frontend_dist. AssetLoader finds it next to the binary at runtime.
#
# In both cases the window navigates to crystkit://localhost/ — no HTTP
# server is started, no port is bound.
# ════════════════════════════════════════════════════════════════════════════

app = CrystKit::App.new(
  CrystKit::AppConfig.new(
    name: "Asset Protocol Example",
    frontend_dist: "#{__DIR__}/frontend",
  )
)

# Register a command so we can verify IPC still works alongside the protocol.
app.command "ping" do
  "pong from Crystal — assets served via #{CrystKit::App.asset_origin}"
end

# No html: or url: argument — the app auto-navigates to crystkit://localhost/
# because AssetLoader found assets (either frontend_dist or CRYSTKIT_ASSETS_PAK)
# and registered the built-in protocol.
app.window(title: "crystkit:// Asset Protocol", width: 720, height: 800, debug: true)

app.run
