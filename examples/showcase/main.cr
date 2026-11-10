require "../../src/crystkit"
require "compress/zlib"
require "digest/crc32"

# Showcase modules
require "./src/custom_plugin"
require "./src/background"
require "./src/commands/sync"
require "./src/commands/shell_box"
require "./src/commands/process_box"
require "./src/commands/websocket_chat"

# ════════════════════════════════════════════════════════════════════════════
# Crystal Webview — Showcase
# Read top-to-bottom; each section is annotated.
# ════════════════════════════════════════════════════════════════════════════

# ─── 1. Configure ───────────────────────────────────────────────────────────
# Capabilities load from a JSON manifest. Storage path comes from the OS
# convention so multiple installs don't collide.

config = CrystKit::AppConfig.new(
  name: "Showcase",
  version: "1.0.0",
  identifier: "dev.crystkit.showcase",
  capabilities_manifest: Path[__DIR__] / "capabilities.json",
  frontend_dist: "#{__DIR__}/assets",
)

app = CrystKit::App.new(config)

# ─── 2. Logging ─────────────────────────────────────────────────────────────
# Crystal stdlib's Log facility, set up at the App-config level. For
# file rotation see CrystKit::Features::AppLogger; this app keeps stderr
# logging for simplicity (visible when run from a terminal).

Log.setup do |c|
  backend = ::Log::IOBackend.new(STDERR)
  c.bind "*", :info, backend
  c.bind "CrystKit::*", :debug, backend
end
Log.info { "showcase: starting (version #{config.version})" }

# ─── 3. Single-instance enforcement ─────────────────────────────────────────
# If another copy of the app is already running, forward our argv to it
# (so e.g. `showcase /tmp/foo.txt` opens that file in the existing window)
# and exit. Otherwise hold the lock.

instance = CrystKit::Features::SingleInstance.new(config.identifier)
unless instance.acquire
  instance.send_to_existing(ARGV)
  Log.info { "showcase: secondary instance, forwarding args and exiting" }
  exit 0
end

# Register a handler before starting the listener — second instance args
# are delivered to every registered handler.
instance.on_receive do |args|
  app.emit("instance:reactivated", {"args" => args})
end
spawn { instance.listen_for_args }
app.on_shutdown { instance.release }

# ─── 4. Deep link handler ───────────────────────────────────────────────────
# Custom URL scheme: showcase://open?path=/tmp/foo
# When the OS launches the app via this URL, parse it and emit an event.

deep_link = CrystKit::Features::DeepLink.new
deep_link.register_scheme("showcase")
deep_link.on_open do |dl|
  Log.info { "deep-link: #{dl.raw_url}" }
  app.emit("deep-link:opened", {
    "url"    => dl.raw_url,
    "scheme" => dl.scheme,
    "host"   => dl.host,
    "path"   => dl.path,
  })
end
deep_link.mark_started

if first = ARGV.first?
  deep_link.handle_url(first) if first.starts_with?("showcase://")
end

# ─── 5. Built-in plugins ────────────────────────────────────────────────────
# frontend JS via `await ipc.invoke(...)`. Capabilities to use them were
# granted by the manifest above.
#
# Plugins are thin IPC adapters — they wire up Features with the correct
# platform backends and security context. Backend Crystal code should use
# Features::* directly instead of routing through plugins.

app.plugin(CrystKit::Plugins::FS.new)
app.plugin(CrystKit::Plugins::Clipboard.new)
app.plugin(CrystKit::Plugins::Dialog.new)
app.plugin(CrystKit::Plugins::Notifications.new)
app.plugin(CrystKit::Plugins::SystemInfo.new)
app.plugin(CrystKit::Plugins::External.new)
app.plugin(CrystKit::Plugins::Store.new)
app.plugin(CrystKit::Plugins::HTTP.new)
app.plugin(CrystKit::Plugins::Theme.new)
app.plugin(CrystKit::Plugins::DPI.new)
app.plugin(CrystKit::Plugins::Power.new)
app.plugin(CrystKit::Plugins::Idle.new)
app.plugin(CrystKit::Plugins::FileWatcher.new)
app.plugin(CrystKit::Plugins::SafeStorage.new)
app.plugin(CrystKit::Plugins::Taskbar.new)
app.plugin(CrystKit::Plugins::Kiosk.new)
app.plugin(CrystKit::Plugins::WEffects.new)
app.plugin(CrystKit::Plugins::DevTools.new)
app.plugin(CrystKit::Plugins::DragDrop.new)
app.plugin(CrystKit::Plugins::ResourceManager.new)
app.plugin(CrystKit::Plugins::DraggableRegion.new)
app.plugin(CrystKit::Plugins::Sidecar.new)
app.plugin(CrystKit::Plugins::Navigation.new)
app.plugin(CrystKit::Plugins::Printing.new)
app.plugin(CrystKit::Plugins::Permissions.new)
app.plugin(CrystKit::Plugins::Hardware.new)
app.plugin(CrystKit::Plugins::Speech.new)
app.plugin(CrystKit::Plugins::Cookie.new)
app.plugin(CrystKit::Plugins::Positioning.new)
app.plugin(CrystKit::Plugins::DragSource.new)
app.plugin(CrystKit::Plugins::DisplayManager.new)
app.plugin(CrystKit::Plugins::WState.new)
app.plugin(CrystKit::Plugins::Toolbar.new)

# ─── 6. Custom plugin ───────────────────────────────────────────────────────
# backend logic and exposing it via IPC to the frontend. Plugin protocol
# example: depends on Store, hooks events, persists state.

app.plugin(RecentsPlugin.new)

# ─── 7. Event bus demo ──────────────────────────────────────────────────────
# Demonstrates the app-wide event bus. The RecentsPlugin (registered below)
# subscribes to "recents:track" events to persist file-open history.
# Backend code can emit events that any plugin or handler observes.
#

app.on("recents:track") { |p| Log.debug { "recents tracked #{p}" } }

# ─── 8. Custom commands ─────────────────────────────────────────────────────
# Each module registers its own typed commands.

Showcase::Commands::Sync.setup(app)
Showcase::Commands::ShellBox.setup(app)
Showcase::Commands::ProcessBox.setup(app)
Showcase::Commands::WebSocketChat.setup(app)

sys = CrystKit::Features::SystemInfo.new
app.command "system.snapshot" do
  os = sys.os_info
  cpu = sys.cpu_info
  mem = sys.memory_info
  {"os" => "#{os.name} #{os.version}", "cpu" => cpu.model,
   "cores" => cpu.cores, "memory_gb" => "%.1f" % [mem.total / 1_073_741_824.0]}
end

# ─── 9. Asset protocol ──────────────────────────────────────────────────────
# Main window assets are served via the crystkit:// protocol (auto-wired
# by App from frontend_dist). The auto-updater API server demo used to run
# on CrystKit::Features::LocalhostServer; that feature now lives in the
# optional crystkit-http-server shard. The updater demo below keeps a fixed
# placeholder port so its commands still type-check and run safely without a
# local server.

port = 38888

# ─── 10. Default window size (first launch only — WState plugin persists thereafter) ─
width = 1100
height = 750

# ─── 11. Open the main window ──────────────────────────────────────────────
# Label is required so the WState plugin can auto-restore position/size.

main_window = app.window(
  title: "Crystal Webview Showcase",
  width: width,
  height: height,
  debug: true,
  label: "main",
)

# Hide to tray instead of quitting when the close button is clicked.
# Platform-agnostic — the native close button is intercepted internally.
main_window.minimize_to_tray = true

# ─── 12. Background streams ─────────────────────────────────────────────────
# Periodic backend events for the live dashboard.

Showcase::Background.start(app)

# ─── 13. System Tray ────────────────────────────────────────────────────────
# Create a system tray icon with context menu. The tray icon provides quick
# access to common actions even when the window is minimized.

tray_icon = Path["tray_icon.png"]

about_options = CrystKit::Features::MessageOptions.new(
  title: "About Crystal Webview Showcase",
  message: "Crystal Webview Showcase\n\nVersion: #{config.version}\nFramework: Webview #{CrystKit::VERSION}\n\nA demonstration of the Crystal Webview framework capabilities.",
  kind: CrystKit::Features::MessageKind::Info,
)

begin
  app.tray do |tray|
    tray.menu do |menu|
      menu.add_item("show", "Show Window") { |_event| main_window.focus }

      menu.add_separator

      menu.add_item("about", "About Showcase") do |_event|
        CrystKit::Features::MessageDialog.new.message(about_options)
      end

      menu.add_separator

      # Submenu demo — nested menus
      window_item = CrystKit::Features::TrayMenuItem.new("window", "Window")
      window_menu = CrystKit::Features::TrayMenu.new
      window_menu.add_item("tile_left", "Tile Left") { |_event|
        main_window.size(width // 2, height, CrystKit::SizeHints::NONE)
        main_window.move(0, 100)
      }
      window_menu.add_item("tile_right", "Tile Right") { |_event|
        main_window.size(width // 2, height, CrystKit::SizeHints::NONE)
        main_window.move(width // 2, 100)
      }
      window_menu.add_separator
      window_menu.add_item("reset_size", "Reset Size") { |_event|
        main_window.size(width, height, CrystKit::SizeHints::NONE)
      }
      window_item.submenu = window_menu
      menu.add_item(window_item)

      menu.add_separator

      menu.add_item("quit", "Quit Showcase") { |_event| main_window.terminate }
    end
    tray.on_click do |button|
      Log.info { "Tray clicked: #{button}" }
      app.emit("tray.clicked", {"button" => button.to_s})
    end
    tray.create(tray_icon, "Crystal Webview Showcase")
    # Only enable minimize-to-tray when the tray is confirmed working —
    # on Linux without a systray, the window would hide with no way to restore.
    main_window.minimize_to_tray = true
    Log.info { "System tray created" }
  end
rescue ex
  Log.warn { "System tray not available: #{ex.message}" }
end

# A plugin also exists — the showcase demonstrates the Feature-direct path here.
# ── Native menu bar ───────────────────────────────────────────────────────────
begin
  menu_bar = CrystKit::Features::MenuBar.new

  app_menu = CrystKit::Features::Menu.new(config.name)
  app_menu.add_item("About DevStation", nil) {
    CrystKit::Features::MessageDialog.new.message(about_options)
  }
  app_menu.add_separator
  app_menu.add_item("Quit", "Cmd+Q") { main_window.terminate }
  menu_bar.add(app_menu)

  app.menu_bar = menu_bar
rescue ex
  Log.warn { "menu bar unavailable: #{ex.message}" }
end
# ─── 14. Global Shortcuts ───────────────────────────────────────────────────
# Register system-wide keyboard shortcuts that work even when the app is
# not focused.

shortcuts = CrystKit::Features::GlobalShortcuts.new

begin
  # Ctrl+Shift+S (or Cmd+Shift+S on macOS) - show window
  shortcuts.register("Meta+Shift+S") do
    Log.info { "Global shortcut triggered: show window" }
    app.emit("shortcut:triggered", {"accelerator" => "Meta+Shift+S", "action" => "show"})
  end

  # Ctrl+Shift+Q (or Cmd+Shift+Q on macOS) - quit
  shortcuts.register("Meta+Shift+Q") do
    Log.info { "Global shortcut triggered: quit" }
    main_window.terminate
  end

  shortcuts.start_listening
  Log.info { "Global shortcuts registered: #{shortcuts.registered.join(", ")}" }
  app.shortcuts = shortcuts
rescue ex
  Log.warn { "Global shortcuts not available: #{ex.message}" }
end

# ─── 15b. Tray and Shortcuts IPC ────────────────────────────────────────

app.command "tray.set_tooltip", String do |text|
  app.tray.try(&.tooltip=(text))
  "ok"
end

app.command "shortcuts.list" do
  shortcuts.registered
end

app.command "shortcuts.register", String do |accelerator|
  shortcuts.register(accelerator) do
    app.emit("shortcut:triggered", {"accelerator" => accelerator})
  end
  "ok"
end

app.command "shortcuts.unregister", String do |accelerator|
  shortcuts.unregister(accelerator)
  "ok"
end

# ─── 16. Autostart ──────────────────────────────────────────────────────────
# Allow the app to register itself to start automatically on login.

# Get the path to the current executable
exe_path = Process.executable_path || "/tmp/showcase"
autostart = CrystKit::Features::Autostart.new("Crystal Webview Showcase", Path.new(exe_path))

# ─── 16a. Screen / Positioning ──────────────────────────────────────────────
# Query display info and cursor position. The screen-change listener
# fires when monitors are added/removed or resolution changes.

positioner = CrystKit::Features::WindowPositioner.new

app.command "screen.list" do
  primary = positioner.screen_info(nil)
  all_screens = (0...positioner.display_count).map do |i|
    info = positioner.screen_info(i)
    {
      "display" => info.display,
      "x"       => info.bounds.x,
      "y"       => info.bounds.y,
      "width"   => info.bounds.width,
      "height"  => info.bounds.height,
      "work_x"  => info.work_area.x,
      "work_y"  => info.work_area.y,
      "work_w"  => info.work_area.width,
      "work_h"  => info.work_area.height,
    }
  end
  {
    "screens" => all_screens,
    "primary" => {
      "display" => primary.display,
      "x"       => primary.bounds.x,
      "y"       => primary.bounds.y,
      "width"   => primary.bounds.width,
      "height"  => primary.bounds.height,
    },
  }
end

app.command "screen.cursor" do
  pt = positioner.cursor
  {"x" => pt.x, "y" => pt.y}
end

screen_changed = false
positioner.on_screen_change { screen_changed = true }

spawn do
  loop do
    sleep 2.seconds
    if screen_changed
      screen_changed = false
      app.emit("screen:changed", {"timestamp" => Time.utc.to_unix_ms})
    end
  end
end

# ─── 16b. Auto-Updater ──────────────────────────────────────────────────────
# Demonstrates update checking, install, rollback, and delta patching. The
# feed URL points at the placeholder port above — the API server demo lives
# in the crystkit-http-server shard, so checks will fail to connect (and
# report "no update") unless a server is running on that port.

updater = CrystKit::Features::AutoUpdater.new(
  "1.5.0",
  "http://localhost:#{port}",
  CrystKit::Features::UpdateChannel::Stable,
  10.seconds
)

app.command "updater.check" do
  info = updater.check_for_updates
  if info
    {"available" => true, "version" => info.version, "release_notes" => info.release_notes}
  else
    {"available" => false}
  end
end

app.command "updater.channel" do
  {"channel" => updater.channel.to_s}
end

app.command "updater.install" do
  info = updater.check_for_updates
  if info
    spawn do
      begin
        pkg = updater.download_update(info)
        updater.install_update(info, pkg)
      rescue ex
        app.emit("updater.error", {"message" => ex.message})
      end
    end
    {"status" => "downloading"}
  else
    {"status" => "no_update"}
  end
end

app.command "updater.rollback" do
  spawn do
    begin
      updater.rollback
    rescue ex
      app.emit("updater.error", {"message" => ex.message})
    end
  end
  {"status" => "rolling_back"}
end

# ─── 16c. TLS / HTTPS info ─────────────────────────────────────────────────
app.command "tls.info" do
  cert_path = Path[__DIR__] / ".." / ".." / "tmp" / "showcase_cert.pem"
  if File.exists?(cert_path)
    {"cert_path" => cert_path.to_s, "tls_enabled" => true}
  else
    {"cert_path" => "", "tls_enabled" => false}
  end
end

# ─── 16d. Enhanced Window Demo ────────────────────────────────────────────
# Spawns a dedicated EnhancedWindow for native window operations demo.

module DemoWindow
  @@instance : CrystKit::Core::Window?

  # EnhancedWindow native operations demo.
  # Note: `modal` requires a parent EnhancedWindow — since the main window
  # is a plain Webview, modal is not available in this demo.
  def self.setup(app : CrystKit::App)
    wv = app.window(
      title: "Demo Window",
      width: 600,
      height: 450,
      label: "demo",
      debug: true,
      url: "data:text/html,<html><body style='background:#1a1a2e;color:#eee;font:16px/1.6 sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;'><div style='text-align:center'><h2>EnhancedWindow Demo</h2><p>Use the Showcase controls to change this window.</p></div></body></html>",
    )
    wv.on_close { wv.hide; false }
    wv
  end

  def self.ensure(app : CrystKit::App)
    wv = @@instance
    if wv.nil?
      wv = setup(app)
      @@instance = wv
    else
      wv.show
      wv.focus
    end
    wv
  end

  def self.instance
    @@instance
  end
end

app.command "window.set_always_on_top", Bool do |top|
  DemoWindow.ensure(app).always_on_top = top
  "ok"
end

app.command "window.set_opacity", Float64 do |opacity|
  DemoWindow.ensure(app).opacity = opacity
  "ok"
end

app.command "window.set_frameless", Bool do |frameless|
  DemoWindow.ensure(app).frameless = frameless
  "ok"
end

app.command "window.info" do
  if wv = DemoWindow.instance
    {
      "always_on_top" => wv.always_on_top?,
      "opacity"       => wv.opacity,
      "frameless"     => wv.frameless?,
    }
  else
    {"error" => "No demo window open. Click any button to create one."}
  end
end

app.command "autostart.status" do
  {"enabled" => autostart.enabled?}
end

app.command "autostart.enable" do
  autostart.enable
  {"enabled" => true}
end

app.command "autostart.disable" do
  autostart.disable
  {"enabled" => false}
end

# ─── 17a. Permissions ────────────────────────────────────────────────────────
# Demonstrate WebView permission request handling by registering a
# handler that allows trusted origins and denies everything else.
begin
  perms_plugin = app.find_plugin?(CrystKit::Plugins::Permissions)
  if perms_plugin
    perms_plugin.permissions_manager.on_request do |req|
      origin_str = req.origin.to_s
      if origin_str == CrystKit::App.asset_origin.rchop('/') || origin_str.starts_with?("https://")
        req.state = CrystKit::Features::PermissionState::Granted
      end
    end
    Log.info { "Permissions handler registered" }
  end
rescue ex
  Log.warn { "Permissions not available: #{ex.message}" }
end

# ─── 17c. Drag Source IPC Command ─────────────────────────────────────────────
# command that starts a drag from frontend-originated data.
begin
  app.command "drag.start", JSON::Any do |payload|
    type_str = payload["type"].as_s
    value = payload["value"].as_s
    source = CrystKit::Features::DragSource.new
    success = case type_str
              when "file" then source.start_file_drag(value)
              when "text" then source.start_text_drag(value)
              when "url"  then source.start_url_drag(value)
              else
                next {"success" => false, "error" => "Unknown type: #{type_str}"}
              end
    {"success" => success}
  end
rescue ex
  Log.warn { "Drag source not available: #{ex.message}" }
end

# ─── 17d. Hardware Enumerate ──────────────────────────────────────────────────
# Live hardware enumeration is provided by the Hardware plugin (registered
# above) via the "hardware:enumerate" command. User code stays platform-agnostic
# and never touches CrystKit::Platform::* directly.

# ─── 17e. Minimize to Tray ────────────────────────────────────────────────────
# Enable minimize-to-tray on the demo enhanced window.
# Applied lazily via command so the window is NOT auto-created on startup.
app.command "window.minimize_to_tray", Bool do |value|
  wv = DemoWindow.ensure(app)
  wv.minimize_to_tray = value
  if value
    wv.on_minimize_to_tray do
      Log.info { "Demo window minimized to tray" }
      app.emit("window:minimized_to_tray", {"label" => "demo"})
    end
  end
  {"minimize_to_tray" => value}
end

# ─── 18. Run ────────────────────────────────────────────────────────────────
# Blocks on the main window's event loop. When the window closes, App#shutdown
# fires plugin cleanup and every registered `on_shutdown` hook (in reverse).

app.run
