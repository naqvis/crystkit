require "../../src/app/app"
require "../../src/plugins/builtins"
require "../../src/features/single_instance"
require "../../src/features/tray"
require "../../src/features/shortcuts"
require "../../src/features/menu"
require "../../src/plugins/builtins/nspanel"

require "./src/store"
require "./src/commands"
require "./src/monitor"
require "./src/ui"

config = CrystKit::AppConfig.new(
  name: "ClipVault",
  version: "2.0.0",
  identifier: "dev.crystkit.clipvault",
  capabilities_manifest: Path[__DIR__] / "capabilities.json",
  frontend_dist: "#{__DIR__}/assets",
)

app = CrystKit::App.new(config)

Log.setup do |c|
  c.bind "*", :info, ::Log::IOBackend.new(STDERR)
end

instance = CrystKit::Features::SingleInstance.new(config.identifier)
unless instance.acquire
  instance.send_to_existing(ARGV)
  exit 0
end
instance.on_receive { |args| app.emit("instance:reactivated", {"args" => args}) }
spawn { instance.listen_for_args }
app.on_shutdown { instance.release }

{% if flag?(:darwin) %}
  app.plugin(CrystKit::Plugins::NSPanel.new({
    "clipvault" => CrystKit::Plugins::NSPanel::PanelOptions.new(
      style_mask: CrystKit::Plugins::NSPanel::Mask::NonactivatingPanel,
      level: CrystKit::Plugins::NSPanel::Level::Floating,
      floating: true,
      movable_by_background: true,
      hover_activate: true,
      has_shadow: true,
      corner_radius: 10.0,
      hides_on_deactivate: false,
      accepts_mouse_moved_events: true,
    ),
  }))
{% end %}

app.plugin(CrystKit::Plugins::FS.new)
  .plugin(CrystKit::Plugins::Clipboard.new)
  .plugin(CrystKit::Plugins::Notifications.new)
  .plugin(CrystKit::Plugins::Dialog.new)
  .plugin(CrystKit::Plugins::Theme.new)
  .plugin(CrystKit::Plugins::Shortcuts.new)

store = ClipVault::Store.open(app.config.storage_dir)
app.on_shutdown { store.close }

handler = ClipVault::Commands.new(store, app.config.storage_dir.to_s)
handler.register(app)

ClipVault::Monitor.start(app, store)

panel = app.window(
  title: "ClipVault",
  width: 400,
  height: 520,
  label: "clipvault",
  visible: false,
  debug: false
)

ClipVault::UI.setup(app, panel)

app.run
