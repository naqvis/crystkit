require "../../src/app/app"
require "../../src/plugins/builtins"
require "../../src/features/single_instance"
require "../../src/features/deep_link"
require "../../src/features/window_state"
require "../../src/features/tray"
require "../../src/features/shortcuts"
require "../../src/features/menu"
require "../../src/features/safe_storage"
require "../../src/features/system_info"
require "../../src/features/power_monitor"
require "../../src/features/idle_monitor"
require "../../src/features/file_watcher"

require "./src/store"
require "./src/vitals_monitor"
require "./src/terminal"
require "./src/http_client"
require "./src/snippets"
require "./src/notes"
require "./src/file_explorer"
require "./src/stats_plugin"

# ════════════════════════════════════════════════════════════════════════════
# CrystKit DevStation — Advanced developer productivity suite
#
# A full-featured native desktop app built with Vue 3 (Vite) on the frontend
# and Crystal on the backend. Every major framework capability is exercised:
#
#   • Vue 3 SPA with Pinia, Vue Router, CodeMirror 6 code editor
#   • Built-in plugins: FS, Dialog, Notifications, SystemInfo, HTTP, Store,
#     Shell, Process, Clipboard, SafeStorage, Theme, DevTools,
#     WebSocket, External, Window, FileWatcher, Power, Idle, Positioning,
#     WState, WEffects, DragDrop
#   • Custom modules: live process streaming, HTTP client with history,
#     snippets/notes manager, system metrics dashboard
#   • Custom plugin (StatsPlugin) with on_window_created JS injection
#   • Reactive state slices (vitals) + event bus (terminal:stdout, …)
#   • Single-instance, deep links, window-state, minimize-to-tray,
#     global shortcuts, native menus, system tray with live tooltip
# ════════════════════════════════════════════════════════════════════════════

Log.setup do |c|
  c.bind "*", :info, ::Log::IOBackend.new(STDERR)
end

# ── App config ───────────────────────────────────────────────────────────────
config = CrystKit::AppConfig.new(
  name: "CrystKit DevStation",
  version: "1.0.0",
  identifier: "dev.crystkit.devstation",
  capabilities_manifest: Path[__DIR__] / "capabilities.json",
  frontend_dist: "#{__DIR__}/frontend/dist",
)

app = CrystKit::App.new(config)

# ── Single instance ───────────────────────────────────────────────────────────
instance = CrystKit::Features::SingleInstance.new(config.identifier)
unless instance.acquire
  instance.send_to_existing(ARGV)
  Log.info { "devstation: already running, forwarding args" }
  exit 0
end
instance.on_receive { |args| app.emit("instance:reactivated", {"args" => args}) }
spawn { instance.listen_for_args }
app.on_shutdown { instance.release }

# ── Deep link: devstation:// ──────────────────────────────────────────────────
deep_link = CrystKit::Features::DeepLink.new
deep_link.register_scheme("devstation")
deep_link.on_open { |dl|
  app.emit("deeplink:opened", {"url" => dl.raw_url, "host" => dl.host, "path" => dl.path})
}
deep_link.mark_started
if (first = ARGV.first?) && first.starts_with?("devstation://")
  deep_link.handle_url(first)
end

# ── Shared in-memory store ───────────────────────────────────────────────────
store = DevStation::Store.open(app.config.storage_dir)
app.on_shutdown { store.close }

# ── Built-in plugins ──────────────────────────────────────────────────────────
app
  .plugin(CrystKit::Plugins::FS.new)
  .plugin(CrystKit::Plugins::Dialog.new)
  .plugin(CrystKit::Plugins::Clipboard.new)
  .plugin(CrystKit::Plugins::Notifications.new)
  .plugin(CrystKit::Plugins::SystemInfo.new)
  .plugin(CrystKit::Plugins::External.new)
  .plugin(CrystKit::Plugins::Store.new)
  .plugin(CrystKit::Plugins::HTTP.new)
  .plugin(CrystKit::Plugins::Shell.new)
  .plugin(CrystKit::Plugins::Process.new)
  .plugin(CrystKit::Plugins::FileWatcher.new)
  .plugin(CrystKit::Plugins::SafeStorage.new)
  .plugin(CrystKit::Plugins::Theme.new)
  .plugin(CrystKit::Plugins::Power.new)
  .plugin(CrystKit::Plugins::Idle.new)
  .plugin(CrystKit::Plugins::DevTools.new)
  .plugin(CrystKit::Plugins::WebSocket.new)
  .plugin(CrystKit::Plugins::Window.new)
  .plugin(CrystKit::Plugins::Positioning.new)
  .plugin(CrystKit::Plugins::WState.new)
  .plugin(CrystKit::Plugins::WEffects.new)
  .plugin(CrystKit::Plugins::DragDrop.new)
  .plugin(StatsPlugin.new(store))

# ── Feature modules ───────────────────────────────────────────────────────────
DevStation::Terminal.setup(app, store)
DevStation::HttpClient.setup(app, store)
DevStation::Snippets.setup(app, store)
DevStation::Notes.setup(app, store)
DevStation::FileExplorer.setup(app, store)

# ── Cross-cutting IPC commands ────────────────────────────────────────────────

app.command "app.theme" do
  begin
    theme_str = app.find_plugin(CrystKit::Plugins::Theme).theme.current.to_s.downcase
    {"theme" => theme_str}
  rescue
    {"theme" => "dark"}
  end
end

app.command "app.open_url", String do |url|
  begin
    app.find_plugin(CrystKit::Plugins::External).opener.open_url(url)
    "ok"
  rescue ex
    {"error" => ex.message.to_s}
  end
end

app.command "app.clipboard_write", String do |text|
  begin
    app.find_plugin(CrystKit::Plugins::Clipboard).clipboard.write_text(text)
    "ok"
  rescue ex
    {"error" => ex.message.to_s}
  end
end

app.command "app.clipboard_read" do
  begin
    app.find_plugin(CrystKit::Plugins::Clipboard).clipboard.read_text
  rescue ex
    {"error" => ex.message.to_s}
  end
end

app.command "app.notify", String, String do |title, body|
  begin
    n = CrystKit::Features::Notification.new(title, body)
    app.find_plugin(CrystKit::Plugins::Notifications).notifications.show(n).id
  rescue ex
    {"error" => ex.message.to_s}
  end
end

# Safe-storage helpers — direct Features access (no plugin wrapper needed)
app.command "app.secret_set", String, String do |key, value|
  safe = CrystKit::Features::SafeStorage.new
  safe.set(key, value, "devstation")
  "ok"
end

app.command "app.secret_get", String do |key|
  safe = CrystKit::Features::SafeStorage.new
  safe.get(key, "devstation")
end

app.command "app.secret_list" do
  safe = CrystKit::Features::SafeStorage.new
  safe.list("devstation").map { |k|
    v = safe.get(k, "devstation")
    preview = v ? (v.size > 4 ? "#{v[0, 2]}••••#{v[-2, 2]}" : "••••") : "—"
    {"key" => k, "preview" => preview}
  }
end

app.command "app.secret_delete", String do |key|
  safe = CrystKit::Features::SafeStorage.new
  safe.delete(key, "devstation")
  "ok"
rescue ex
  {"error" => ex.message.to_s}
end
app.command "app.devtools_toggle" do
  begin
    dt = app.find_plugin(CrystKit::Plugins::DevTools).devtools
    app.primary_window.try do |window|
      window.devtools = dt
      window.toggle_devtools
    end
    "ok"
  rescue ex
    {"error" => ex.message.to_s}
  end
end

# Multi-window: terminal pop-out
app.command "app.open_terminal_window" do
  base = app.dev_url || CrystKit::App.asset_origin
  app.window(title: "DevStation Terminal", width: 900, height: 600, url: "#{base}#/terminal")
  {"opened" => true}
end

# ── Window-state persistence ──────────────────────────────────────────────────
win_state = CrystKit::Features::WindowState.new("main", storage_dir: app.config.storage_dir)
saved = win_state.restore
width = saved.try(&.width) || 1440
height = saved.try(&.height) || 900

# ── Main window ───────────────────────────────────────────────────────────────
main_window = app.window(
  title: "CrystKit DevStation",
  width: width,
  height: height,
  debug: false, # DevTools enabled by plugin via setInspectable + developerExtrasEnabled
)
# minimize_to_tray is set below only when tray creation succeeds

main_window.window_state = win_state

# Raw bind_typed — zero-overhead direct Crystal↔JS bridge, bypasses IPC registry
sysinfo = CrystKit::Features::SystemInfo.new
main_window.bind_typed("devstation_ping", String) { |msg|
  "#{msg} → pong from #{sysinfo.hostname} (CrystKit #{CrystKit::VERSION})"
}

# ── System tray ───────────────────────────────────────────────────────────────
tray_icon = Path.new("tray_icon.png")

begin
  app.tray do |tray|
    tray.menu do |menu|
      menu.add_item("show", "Show DevStation") { |_| main_window.focus }

      menu.add_separator

      menu.add_item("terminal", "New Terminal Window") { |_| app.emit("tray:action", {"action" => "terminal"}) }

      menu.add_separator

      menu.add_item("devtools", "Toggle DevTools") { |_|
        begin
          dt = app.find_plugin(CrystKit::Plugins::DevTools).devtools
          main_window.devtools = dt
          main_window.toggle_devtools
        rescue ex
          Log.warn { "devtools toggle failed: #{ex.message}" }
        end
      }

      menu.add_separator

      menu.add_item("quit", "Quit DevStation") { |_| main_window.terminate }
    end
    tray.on_click { |btn|
      app.emit("tray.click", {"button" => btn.to_s.downcase})
      main_window.focus if btn.to_s == "Left"
    }

    tray.create(tray_icon, "CrystKit DevStation")
    # Only enable minimize-to-tray when the tray is confirmed working -
    # on Linux without a systray, the window would hide with no way to restore.
    main_window.minimize_to_tray = true
  end
rescue ex
  Log.warn { "tray unavailable: #{ex.message}" }
end

# Live tray tooltip updated from the vitals state slice via a backend-side
# callback — no event bus needed. The state slice handles frontend reactivity;
# the tray (backend-side) gets the typed value directly.
DevStation::VitalsMonitor.setup(app, store, on_tick: ->(s : DevStation::VitalsMonitor::VitalsState) {
  tray = app.tray
  return unless tray
  tray.tooltip = "DevStation • CPU #{s.cpu.usage_pct.round(1)}% • MEM #{s.memory.used_pct.round(1)}%" rescue nil
})

# ── Global shortcuts ──────────────────────────────────────────────────────────
shortcuts = CrystKit::Features::GlobalShortcuts.new
begin
  shortcuts.register("Meta+Shift+D") {
    main_window.focus
    app.emit("shortcut:triggered", {"action" => "focus", "key" => "Meta+Shift+D"})
  }
  shortcuts.register("Meta+Shift+T") {
    app.emit("shortcut:triggered", {"action" => "new_terminal", "key" => "Meta+Shift+T"})
  }
  shortcuts.register("Meta+Shift+F") {
    app.emit("shortcut:triggered", {"action" => "file_search", "key" => "Meta+Shift+F"})
  }
  shortcuts.start_listening
  app.shortcuts = shortcuts
rescue ex
  Log.warn { "shortcuts unavailable: #{ex.message}" }
end

# ── Native menu bar ───────────────────────────────────────────────────────────
begin
  menu_bar = CrystKit::Features::MenuBar.new

  app_menu = CrystKit::Features::Menu.new(config.name)
  app_menu.add_item("About DevStation", nil) {
    if plugin = app.find_plugin?(CrystKit::Plugins::Dialog)
      plugin.message_dialog.message(CrystKit::Features::MessageOptions.new(
        title: "About CrystKit DevStation",
        message: "CrystKit DevStation\n\nVersion: #{config.version}\nFramework: CrystKit #{CrystKit::VERSION}\n\nA full-featured developer productivity suite built with Crystal + WebView.\n\nFeatures: Terminal · HTTP Client · File Explorer · Snippets · Notes",
        kind: CrystKit::Features::MessageKind::Info,
      ))
    end
  }
  app_menu.add_separator
  app_menu.add_item("Quit", "Cmd+Q") { main_window.terminate }
  menu_bar.add(app_menu)

  file_menu = CrystKit::Features::Menu.new("File")
  file_menu.add_item("New Snippet", "Cmd+N") { app.emit("menu:action", {"action" => "new_snippet"}) }
  file_menu.add_item("New Note", "Cmd+Shift+N") { app.emit("menu:action", {"action" => "new_note"}) }
  file_menu.add_separator
  file_menu.add_item("Open File…", "Cmd+O") { app.emit("menu:action", {"action" => "open_file"}) }
  file_menu.add_item("Save", "Cmd+S") { app.emit("menu:action", {"action" => "save"}) }
  menu_bar.add(file_menu)

  view_menu = CrystKit::Features::Menu.new("View")
  view_menu.add_item("Terminal", "Cmd+`") { app.emit("menu:action", {"action" => "view_terminal"}) }
  view_menu.add_item("HTTP Client", "Cmd+Shift+H") { app.emit("menu:action", {"action" => "view_http"}) }
  view_menu.add_separator
  view_menu.add_item("Toggle DevTools", "Cmd+Alt+I") {
    begin
      dt = app.find_plugin(CrystKit::Plugins::DevTools).devtools
      main_window.devtools = dt
      main_window.toggle_devtools
    rescue ex
      Log.warn { "devtools toggle failed: #{ex.message}" }
    end
  }
  menu_bar.add(view_menu)

  app.menu_bar = menu_bar
rescue ex
  Log.warn { "menu bar unavailable: #{ex.message}" }
end

# ── Theme propagation + start OS monitor ─────────────────────────────────────
app.on("theme.changed") { |p| app.emit("app:theme_changed", p) }

# Start the OS theme monitor on boot and fan out changes over the event bus.
# The plugin's theme:start_monitor IPC command does the same thing from the
# frontend; doing it here means the tray/menu can also react to theme changes.
spawn(name: "theme-monitor-boot") do
  until app.running?
    sleep 100.milliseconds
  end
  begin
    th = app.find_plugin(CrystKit::Plugins::Theme).theme
    channel = th.start_monitor(3.seconds)
    loop do
      new_theme = channel.receive
      app.emit("theme.changed", {"theme" => new_theme})
    end
  rescue ex
    Log.warn { "theme monitor unavailable: #{ex.message}" }
  end
end

Log.info { "devstation: ready — #{config.name} v#{config.version}" }

# ── Frontend error logging ────────────────────────────────────────────────────
# The IPC bridge emits this when a backend command returns an error object.
# Since production WebView apps have no DevTools, this routes JS-side errors
# into the Crystal app log (stderr / log file) where they are always visible.
app.on("app:frontend_error") do |payload|
  if h = payload.as_h?
    cmd = h["cmd"]?.try(&.as_s) || "unknown"
    msg = h["msg"]?.try(&.as_s) || "unknown error"
    Log.error { "frontend: command '#{cmd}' failed — #{msg}" }
  end
end

app.run
