require "../../src/crystkit"
require "../../src/plugins/builtins"
require "../../src/features/single_instance"
require "../../src/features/deep_link"
require "../../src/features/menu"
require "../../src/features/tray"
require "../../src/features/shortcuts"
require "../../src/features/window_state"

require "./src/store"
require "./src/parser"
require "./src/feeds"
require "./src/articles"
require "./src/search"
require "./src/fetcher"
require "./src/opml"
require "./src/popout"
require "./src/notifications"
require "./src/deep_links"

config = CrystKit::AppConfig.new(
  name: "FluxReader",
  version: "1.0.0",
  identifier: "com.crystkit.fluxreader",
  capabilities_manifest: Path[__DIR__] / "capabilities.json",
  frontend_dist: "#{__DIR__}/frontend",
)

app = CrystKit::App.new(config)

Log.setup do |c|
  c.bind "*", :info, ::Log::IOBackend.new(STDERR)
end

# ── Single instance ──
instance = CrystKit::Features::SingleInstance.new(config.identifier)
unless instance.acquire
  instance.send_to_existing(ARGV)
  exit 0
end
instance.on_receive { |args| app.emit("instance:reactivated", {"args" => args}) }
spawn { instance.listen_for_args }
app.on_shutdown { instance.release }

# ── Deep link: fluxreader:// ──
deep_link = CrystKit::Features::DeepLink.new
deep_link.register_scheme("fluxreader")
deep_link.on_open { |dl| app.emit("deeplink:subscribe", {"url" => dl.query_params["url"]?}) }
deep_link.mark_started
first_arg = ARGV.first?

# ── Shared in-memory store ──
store = FluxReader::Store.open(app.config.storage_dir)
app.on_shutdown { store.close }

# ── Built-in plugins ──
app
  .plugin(CrystKit::Plugins::Dialog.new)
  .plugin(CrystKit::Plugins::Clipboard.new)
  .plugin(CrystKit::Plugins::Notifications.new)
  .plugin(CrystKit::Plugins::SystemInfo.new)
  .plugin(CrystKit::Plugins::External.new)
  .plugin(CrystKit::Plugins::Store.new)
  .plugin(CrystKit::Plugins::HTTP.new)
  .plugin(CrystKit::Plugins::Theme.new)
  .plugin(CrystKit::Plugins::Window.new)
  .plugin(CrystKit::Plugins::DevTools.new)
  .plugin(CrystKit::Plugins::DragDrop.new)
  .plugin(CrystKit::Plugins::ContextMenu.new)
  .plugin(CrystKit::Plugins::Logging.new)
  .plugin(CrystKit::Plugins::FileWatcher.new)
  .plugin(CrystKit::Plugins::Taskbar.new)
  .plugin(CrystKit::Plugins::Autostart.new)

# ── Wire backend modules ──
FluxReader::Feeds.setup(app, store)
FluxReader::Articles.setup(app, store)
FluxReader::Search.setup(app, store)
FluxReader::OPML.setup(app, store)
FluxReader::Fetcher.setup(app, store)
FluxReader::Popout.setup(app, store)
FluxReader::Notifications.setup(app)
FluxReader::DeepLinks.setup(app, first_arg)

# ── Context menu handlers ──
cm = app.find_plugin(CrystKit::Plugins::ContextMenu).context_menu

cm.on_element("fluxreader-article") do |b|
  b.add("Mark Read", "mark-read")
  b.add("Toggle Favorite", "toggle-fav")
  b.add("Pop Out", "pop-out")
end

cm.on_element("fluxreader-feed") do |b|
  b.add("Refresh Feed", "refresh-feed")
  b.add("Change Category…", "change-category")
  b.add("Remove Feed", "remove-feed")
end

cm.on_element("fluxreader-view") do |b|
  b.add("Mark All Read", "mark-all-read")
end

# ── Menu action handler (shared by menu, tray, shortcuts) ──
app.on("menu:action") do |payload|
  action = payload["action"]?.try(&.as_s) || ""
  app.primary_window
  case action
  when "settings"       then app.emit("ui:show_settings", JSON::Any.new({} of String => JSON::Any))
  when "subscribe"      then app.emit("ui:show_subscribe", JSON::Any.new({} of String => JSON::Any))
  when "refresh_all"    then spawn { FluxReader::Fetcher.refresh_all(app, store) }
  when "import_opml"    then app.emit("ui:import_opml", JSON::Any.new({} of String => JSON::Any))
  when "export_opml"    then app.emit("ui:export_opml", JSON::Any.new({} of String => JSON::Any))
  when "view_all"       then app.emit("ui:set_view", {"view" => "all"})
  when "view_unread"    then app.emit("ui:set_view", {"view" => "unread"})
  when "view_favorites" then app.emit("ui:set_view", {"view" => "favorites"})
  when "mark_all_read"  then FluxReader::Articles.setup(app, store); app.emit("ui:mark_all_read", JSON::Any.new({} of String => JSON::Any))
  when "about"          then show_about(app, config)
  end
end

app.on("shortcut:triggered") { |p| app.emit("menu:action", p) }
app.on("tray:action") { |p| app.emit("menu:action", p) }

# ── Main window ──
main_window = app.window(
  title: "FluxReader",
  width: 1200,
  height: 760,
  label: "main",
)

# ── Native menu bar ──
begin
  menu_bar = CrystKit::Features::MenuBar.new

  app_menu = CrystKit::Features::Menu.new("FluxReader")
  app_menu.add_item("About FluxReader") { show_about(app, config) }
  app_menu.add_separator
  app_menu.add_item("Settings…", "Cmd+,") { app.emit("menu:action", {"action" => "settings"}) }
  app_menu.add_separator
  app_menu.add_item("Quit", "Cmd+Q") { main_window.terminate }
  menu_bar.add(app_menu)

  file_menu = CrystKit::Features::Menu.new("File")
  file_menu.add_item("Subscribe…", "Cmd+N") { app.emit("menu:action", {"action" => "subscribe"}) }
  file_menu.add_item("Refresh All", "Cmd+R") { app.emit("menu:action", {"action" => "refresh_all"}) }
  file_menu.add_separator
  file_menu.add_item("Import OPML…") { app.emit("menu:action", {"action" => "import_opml"}) }
  file_menu.add_item("Export OPML…") { app.emit("menu:action", {"action" => "export_opml"}) }
  menu_bar.add(file_menu)

  edit_menu = CrystKit::Features::Menu.new("Edit")
  edit_menu.add_item("Undo", "Cmd+Z") { main_window.eval("document.execCommand('undo')") }
  edit_menu.add_item("Redo", "Cmd+Shift+Z") { main_window.eval("document.execCommand('redo')") }
  edit_menu.add_separator
  edit_menu.add_item("Cut", "Cmd+X") { main_window.eval("document.execCommand('cut')") }
  edit_menu.add_item("Copy", "Cmd+C") { main_window.eval("document.execCommand('copy')") }
  edit_menu.add_item("Paste", "Cmd+V") { main_window.eval("document.execCommand('paste')") }
  edit_menu.add_separator
  edit_menu.add_item("Select All", "Cmd+A") { main_window.eval("document.execCommand('selectAll')") }
  menu_bar.add(edit_menu)

  view_menu = CrystKit::Features::Menu.new("View")
  view_menu.add_item("All Articles", "Cmd+1") { app.emit("menu:action", {"action" => "view_all"}) }
  view_menu.add_item("Unread", "Cmd+2") { app.emit("menu:action", {"action" => "view_unread"}) }
  view_menu.add_item("Favorites", "Cmd+3") { app.emit("menu:action", {"action" => "view_favorites"}) }
  view_menu.add_separator
  view_menu.add_item("Mark All Read", "Cmd+Shift+N") { app.emit("menu:action", {"action" => "mark_all_read"}) }
  view_menu.add_separator
  view_menu.add_item("Toggle DevTools", "Cmd+Alt+I") { main_window.toggle_devtools }
  menu_bar.add(view_menu)

  window_menu = CrystKit::Features::Menu.new("Window")
  window_menu.add_item("Minimize", "Cmd+M") { main_window.minimize }
  window_menu.add_item("Close", "Cmd+W") { main_window.hide }
  menu_bar.add(window_menu)

  help_menu = CrystKit::Features::Menu.new("Help")
  help_menu.add_item("FluxReader Help") {
    app.find_plugin(CrystKit::Plugins::External).opener.open_url("https://crystkit.dev/fluxreader")
  }
  menu_bar.add(help_menu)

  app.menu_bar = menu_bar
rescue ex
  Log.warn { "fluxreader: menu bar unavailable: #{ex.message}" }
end

# ── System tray ──
begin
  tray_icon = Path.new("icons/tray.png")

  app.tray do |tray|
    tray.menu do |menu|
      menu.add_item("show", "Show FluxReader") { |_| main_window.focus }
      menu.add_separator
      menu.add_item("refresh", "Refresh All") { |_| app.emit("tray:action", {"action" => "refresh_all"}) }
      menu.add_item("mark_read", "Mark All Read") { |_| app.emit("tray:action", {"action" => "mark_all_read"}) }
      menu.add_separator
      menu.add_item("settings", "Settings") { |_| app.emit("tray:action", {"action" => "settings"}) }
      menu.add_separator
      menu.add_item("quit", "Quit FluxReader") { |_| main_window.terminate }
    end
    tray.on_click { |btn| main_window.focus if btn.to_s == "Left" }

    tray.create(tray_icon, "FluxReader")
    main_window.minimize_to_tray = true

    app.on("tray:update_unread") do |payload|
      count = payload["unread"]?.try(&.as_i64) || 0
      tray.tooltip = count > 0 ? "FluxReader — #{count} unread" : "FluxReader" rescue nil
    end
  end
rescue ex
  Log.warn { "fluxreader: tray unavailable: #{ex.message}" }
end

# ── Global shortcuts ──
begin
  shortcuts = CrystKit::Features::GlobalShortcuts.new
  shortcuts.register("Cmd+1") { app.emit("shortcut:triggered", {"action" => "view_all"}) }
  shortcuts.register("Cmd+2") { app.emit("shortcut:triggered", {"action" => "view_unread"}) }
  shortcuts.register("Cmd+3") { app.emit("shortcut:triggered", {"action" => "view_favorites"}) }
  shortcuts.register("Cmd+R") { app.emit("shortcut:triggered", {"action" => "refresh_all"}) }
  shortcuts.register("Cmd+N") { app.emit("shortcut:triggered", {"action" => "subscribe"}) }
  shortcuts.register("Cmd+Shift+N") { app.emit("shortcut:triggered", {"action" => "mark_all_read"}) }
  shortcuts.register("Cmd+,") { app.emit("shortcut:triggered", {"action" => "settings"}) }
  shortcuts.start_listening
  app.shortcuts = shortcuts
rescue ex
  Log.warn { "fluxreader: shortcuts unavailable: #{ex.message}" }
end

# ── Theme propagation ──
app.on("theme.changed") { |p| app.emit("app:theme_changed", p) }

spawn(name: "fluxreader-theme-monitor") do
  until app.running?
    sleep 100.milliseconds
  end
  begin
    th = app.find_plugin(CrystKit::Plugins::Theme).theme
    th.start_monitor(3.seconds)
    loop do
      sleep 3.seconds
    end
  rescue ex
  end
end

# ── Deferred startup refresh ──
app.on_ready do |_|
  spawn do
    sleep 1.second
    FluxReader::Fetcher.refresh_all(app, store)
  end
end

# ── Frontend error logging ──
app.on("app:frontend_error") do |payload|
  if h = payload.as_h?
    cmd = h["cmd"]?.try(&.as_s) || "unknown"
    msg = h["msg"]?.try(&.as_s) || "unknown error"
    Log.error { "fluxreader: frontend command '#{cmd}' failed — #{msg}" }
  end
end

# ── Data clear command ──
app.command "data.clear" do
  store.clear_all
  true
end

Log.info { "fluxreader: ready — #{config.name} v#{config.version}" }

app.run

# ── Helpers ──
def show_about(app : CrystKit::App, config : CrystKit::AppConfig)
  app.find_plugin(CrystKit::Plugins::Dialog).message_dialog.message(CrystKit::Features::MessageOptions.new(
    title: "About FluxReader",
    message: "FluxReader #{config.version}\nBuilt with CrystKit #{CrystKit::VERSION}\n\nA native desktop RSS/Atom feed reader showcasing CrystKit framework capabilities.",
    kind: CrystKit::Features::MessageKind::Info,
  ))
rescue ex
  Log.warn { "fluxreader: about dialog failed: #{ex.message}" }
end
