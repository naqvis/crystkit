require "./spec_helper"
require "./ipc_bridge_spec"
require "../src/app/app"
require "../src/plugins/builtins/clipboard"
require "../src/plugins/builtins/dialog"
require "../src/plugins/builtins/external"
require "../src/plugins/builtins/fs"
require "../src/plugins/builtins/http"
require "../src/plugins/builtins/notifications"
require "../src/plugins/builtins/store"
require "../src/plugins/builtins/system_info"
require "../src/features/shortcuts"
require "../src/features/taskbar_progress"
require "../src/features/tray"
require "../src/features/window_effects"
require "../src/features/window_state"

private class AppSpecMenuProvider < CrystKit::Features::MenuBar::Provider
  getter installs = [] of {String, Void*?}

  def requires_running_event_loop? : Bool
    false
  end

  def install(menu_bar, window_ptr : Void*?) : Nil
    label = menu_bar.menus.first?.try(&.label) || ""
    @installs << {label, window_ptr}
  end
end

private class AppSpecDeferredMenuProvider < AppSpecMenuProvider
  def requires_running_event_loop? : Bool
    true
  end
end

private class AppSpecWindowBackend < CrystKit::Platform::WindowBackend
  def create_window(title, width, height, hint, debug, label, visible) : CrystKit::Core::EnhancedWindow
    CrystKit::Core::EnhancedWindow.fake(debug, title, label)
  end

  def configure_content(window : CrystKit::Core::EnhancedWindow, url : String?, html : String?) : Nil
  end
end

private class AppSpecTrayProvider < CrystKit::Features::SystemTray::Provider
  getter? destroyed = false

  def create(app_id : String, icon : CrystKit::Platform::IconSource?, tooltip : String?) : Nil
  end

  def on_click(&_block : Int32 ->) : Nil
  end

  def update_icon(icon : CrystKit::Platform::IconSource) : Nil
  end

  def set_menu(items : Array(CrystKit::Platform::TrayMenuEntry), callbacks : Hash(String, Proc(Nil))) : Nil
  end

  def tooltip=(text : String) : Nil
  end

  def destroy : Nil
    @destroyed = true
  end
end

private class AppSpecShortcutsProvider < CrystKit::Features::GlobalShortcuts::Provider
  getter? stopped = false

  def register(shortcut : CrystKit::Features::Shortcut, handler : Proc(Nil)) : Nil
  end

  def unregister(shortcut : CrystKit::Features::Shortcut) : Nil
  end

  def start : Nil
  end

  def stop : Nil
    @stopped = true
  end
end

private class AppSpecTaskbarProvider < CrystKit::Features::TaskbarProgress::Provider
  getter progress_value : Float64?

  def attach(window : Void*, application_id : String) : Nil
  end

  def progress=(value : Float64) : Nil
    @progress_value = value
  end

  def clear_progress : Nil
  end

  def badge=(text : String?) : Nil
  end

  def overlay_icon=(icon : ::CrystKit::Platform::IconSource?) : Nil
  end

  def state=(state : CrystKit::Features::TaskbarProgress::ProgressState) : Nil
  end

  def cleanup : Nil
  end
end

private class AppSpecNotificationsProvider < CrystKit::Features::Notifications::Provider
  def request_permission(app_name : String) : Bool
    true
  end

  def show(app_name : String, id : String, title : String, body : String,
           icon : ::CrystKit::Platform::IconSource?,
           urgency : Int32, timeout_ms : Int32,
           actions : Array({String, String})) : Nil
  end

  def close(id : String) : Nil
  end
end

private class AppSpecWindowIntegrationBackend < CrystKit::Platform::WindowIntegrationBackend
  def prepare_permissions : Nil
  end

  def register_permissions(window : CrystKit::Webview, &_handler : String, String -> String) : Nil
  end

  def enable_devtools(window : CrystKit::Webview) : Nil
  end

  def open_devtools(native_window : Pointer(Void), dock_mode : Int32) : Nil
  end

  def close_devtools(native_window : Pointer(Void)) : Nil
  end
end

private class FrontendEventTestPlugin < CrystKit::Plugin::Base
  def identifier : String
    "fe_test"
  end

  def metadata : CrystKit::Plugin::Metadata
    CrystKit::Plugin::Metadata.new(
      identifier,
      commands: %w(fe.test.echo),
      events: %w(fe.test.broadcast),
      frontend_events: %w(fe.test.ping),
    )
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    context.command "fe.test.echo" do
      JSON::Any.new("ok")
    end
  end
end

private def invoke_via_bridge(host : SpecIPC::BridgeHost, command : String, params : JSON::Any?)
  SpecIPC.invoke_via_bridge(host, command, params)
end

describe CrystKit::App do
  describe "construction" do
    it "creates IPC, capabilities, scopes, and window store without arguments" do
      SpecHelpers.with_temp_dir do |dir|
        config = CrystKit::AppConfig.new(
          name: "Test",
          identifier: "test.app.construction",
          storage_dir: Path[dir],
        )
        app = CrystKit::App.new(config)
        app.router.should be_a(CrystKit::IPC::Router)
        app.router.should be_a(CrystKit::IPC::Router)
        app.router.should be(app.router)
        app.capabilities.should be_a(CrystKit::Security::CapabilitySystem)
        app.scopes.should be_a(CrystKit::Security::ScopeManager)
        app.windows.should be_empty
        app.running?.should be_false
        app.primary_window.should be_nil
      end
    end
    it "creates the storage directory" do
      SpecHelpers.with_temp_dir do |dir|
        target = Path[dir] / "nested" / "store"
        config = CrystKit::AppConfig.new(storage_dir: target)
        CrystKit::App.new(config)
        Dir.exists?(target.to_s).should be_true
      end
    end
    it "registers config-driven IPC command overrides without command boilerplate" do
      config = CrystKit::AppConfig.new(
        ipc: CrystKit::IPCConfig.new({
          "notes.sync_everything" => CrystKit::IPCCommandOverride.new(
            capability: "notes:write",
            resource: "workspace",
            resource_kind: "resource",
            permission: "write",
          ),
        })
      )
      app = CrystKit::App.new(config)
      policy = app.router.policy_resolver.resolve("notes.sync_everything")
      policy.capability.should eq("notes:write")
      policy.resources.size.should eq(1)
      policy.resources.first.capability.should eq("notes:write")
      policy.resources.first.kind.should eq(CrystKit::IPC::ResourceKind::Resource)
      policy.resources.first.permission.should eq(CrystKit::IPC::ResourcePermission::Write)
    end
  end
  describe "#grant" do
    it "grants capabilities and persists across calls" do
      app = make_app
      app.grant("fs:read", "fs:write")
      app.capabilities.check("fs:read").should be_true
      app.capabilities.check("fs:write").should be_true
      app.capabilities.check("fs:delete").should be_false
    end
    it "returns self for chaining" do
      app = make_app
      app.grant("foo").should be(app)
    end
  end
  describe "#quit" do
    it "shuts down the app when it is not running" do
      app = make_app
      called = false
      app.on_shutdown { called = true }
      app.quit
      called.should be_true
    end
  end
  describe "#terminate" do
    it "is an app-level alias for quit" do
      app = make_app
      called = false
      app.on_shutdown { called = true }
      app.terminate
      called.should be_true
    end
  end
  describe "#menu_bar" do
    it "defers native menu installation until the application run loop starts" do
      menu_provider = AppSpecDeferredMenuProvider.new
      platform = CrystKit::Platform::Services.new(
        window: AppSpecWindowBackend.new,
      )
      app = CrystKit::App.new(platform: platform)
      app.window(label: "main")
      menu = CrystKit::Features::MenuBar.new(menu_provider)
      menu.add(CrystKit::Features::Menu.new("File"))
      app.menu_bar = menu
      menu_provider.installs.should be_empty

      app.run
      menu_provider.installs.size.should eq(1)
    end

    it "stores a menu bar through assignment and installs it when the primary window exists" do
      menu_provider = AppSpecMenuProvider.new
      platform = CrystKit::Platform::Services.new(
        window: AppSpecWindowBackend.new,
      )
      app = CrystKit::App.new(platform: platform)
      app.window(label: "main")
      menu = CrystKit::Features::MenuBar.new(menu_provider)
      menu.add(CrystKit::Features::Menu.new("File"))
      app.menu_bar = menu
      app.menu_bar.should be(menu)
      menu_provider.installs.size.should eq(1)
      menu_provider.installs.first[0].should eq("File")
    end
    it "builds and installs a menu bar with a block" do
      app = CrystKit::App.new
      app.menu_bar do |menu|
        menu.menu("File") { |file| file.item("Quit") { } }
      end
      app.menu_bar.not_nil!.menus.first.label.should eq("File")
    end
    it "applies an assigned menu bar to a window created later" do
      menu_provider = AppSpecMenuProvider.new
      platform = CrystKit::Platform::Services.new(
        window: AppSpecWindowBackend.new,
      )
      app = CrystKit::App.new(platform: platform)
      menu = CrystKit::Features::MenuBar.new(menu_provider)
      menu.add(CrystKit::Features::Menu.new("File"))
      app.menu_bar = menu
      menu_provider.installs.should be_empty
      app.window(label: "main")
      menu_provider.installs.size.should eq(1)
    end
    it "applies an all-windows menu to existing and future windows" do
      menu_provider = AppSpecMenuProvider.new
      platform = CrystKit::Platform::Services.new(
        window: AppSpecWindowBackend.new,
      )
      app = CrystKit::App.new(platform: platform)
      app.window(label: "main")
      menu = CrystKit::Features::MenuBar.new(menu_provider)
      menu.add(CrystKit::Features::Menu.new("Global"))
      app.menu_bar(menu, target: :all)
      menu_provider.installs.size.should eq(1)
      app.window(label: "settings")
      menu_provider.installs.size.should eq(2)
    end
    it "applies a labeled menu only when the matching window exists" do
      menu_provider = AppSpecMenuProvider.new
      platform = CrystKit::Platform::Services.new(
        window: AppSpecWindowBackend.new,
      )
      app = CrystKit::App.new(platform: platform)
      menu = CrystKit::Features::MenuBar.new(menu_provider)
      menu.add(CrystKit::Features::Menu.new("Settings"))
      app.menu_bar(menu, target: "settings")
      app.window(label: "main")
      menu_provider.installs.should be_empty
      app.window(label: "settings")
      menu_provider.installs.size.should eq(1)
      menu_provider.installs.first[0].should eq("Settings")
    end
  end
  describe "app-owned native feature accessors" do
    it "stores and builds system tray features through App" do
      tray_provider = AppSpecTrayProvider.new
      app = CrystKit::App.new
      tray = CrystKit::Features::SystemTray.new(app.capabilities, provider: tray_provider, app_id: "com.test.app")
      app.tray = tray
      app.tray.should be(tray)
      built = app.tray { |_created| }
      app.tray.should be(built)
    end
    it "stores and builds global shortcuts through App and stops them on shutdown" do
      shortcuts_provider = AppSpecShortcutsProvider.new
      app = CrystKit::App.new
      built = app.shortcuts do |created|
        created.register("Cmd+Shift+P") { }
      end
      app.shortcuts.should be(built)
      shortcuts = CrystKit::Features::GlobalShortcuts.new(shortcuts_provider)
      app.shortcuts = shortcuts
      app.shortcuts.should be(shortcuts)
      shortcuts.start_listening
      app.shutdown
      shortcuts_provider.stopped?.should be_true
    end
    it "stores and builds taskbar progress through App" do
      taskbar_provider = AppSpecTaskbarProvider.new
      app = CrystKit::App.new
      progress = CrystKit::Features::TaskbarProgress.new(taskbar_provider)
      app.taskbar_progress = progress
      app.taskbar_progress.should be(progress)
      built = app.taskbar_progress do |created|
        created.progress = 0.42
      end
      app.taskbar_progress.should be(built)
      built.progress.should eq(0.42)
    end
    it "stores and builds notifications through App" do
      notifications_provider = AppSpecNotificationsProvider.new
      app = CrystKit::App.new
      notifications = CrystKit::Features::Notifications.new(app.capabilities, provider: notifications_provider, app_name: "Test App")
      notifications.request_permission.should be_true
      app.notifications = notifications
      app.notifications.should be(notifications)
      built = app.notifications do |created|
        created.should be_a(CrystKit::Features::Notifications)
      end
      app.notifications.should be(built)
    end
  end
  describe "window-owned native feature accessors" do
    it "stores window effects through the Window API" do
      app = CrystKit::App.new(
        platform: CrystKit::Platform::Services.new(window: AppSpecWindowBackend.new)
      )
      window = app.window(label: "main")
      effects = CrystKit::Features::WindowEffects.new
      window.effects = effects
      window.effects.should be(effects)
      built = window.effects do |created|
        created.config.mica = true
      end
      window.effects.should be(built)
      window.effects.not_nil!.config.mica?.should be_true
    end
    it "stores and controls devtools through the Window API" do
      app = CrystKit::App.new(
        platform: CrystKit::Platform::Services.new(window: AppSpecWindowBackend.new)
      )
      window = app.window(label: "main")
      devtools = CrystKit::Features::DevTools.new(
        CrystKit::Features::DevToolsConfig.new(enabled: true),
        AppSpecWindowIntegrationBackend.new,
      )
      window.devtools = devtools
      window.devtools.should be(devtools)
      window.open_devtools
      window.devtools.not_nil!.open?.should be_true
      window.toggle_devtools
      window.devtools.not_nil!.open?.should be_false
    end
    it "stores window state and saves current window data" do
      SpecHelpers.with_temp_dir do |dir|
        app = CrystKit::App.new(
          platform: CrystKit::Platform::Services.new(window: AppSpecWindowBackend.new)
        )
        window = app.window(label: "main")
        window.size(900, 700)
        state = CrystKit::Features::WindowState.new("main", storage_dir: Path[dir])
        window.window_state = state
        window.window_state.should be(state)
        window.save_window_state
        restored = state.restore
        restored.should_not be_nil
        restored.not_nil!.width.should eq(900)
        restored.not_nil!.height.should eq(700)
      end
    end
  end
  describe "#command and #emit" do
    it "registers a typed command that decodes the complete payload" do
      app = make_app
      app.command "greet", String do |name|
        "Hello, #{name}"
      end
      result = app.router.invoke_command("greet", JSON.parse(%("World")))
      result.as_s.should eq("Hello, World")
    end
    it "decodes multiple typed parameters from an ordered array" do
      app = make_app
      app.command "add", Int32, Int32 do |a, b|
        a + b
      end
      result = app.router.invoke_command("add", JSON.parse(%([3,4])))
      result.as_i.should eq(7)
    end
    it "rejects object payloads for multiple typed parameters" do
      app = make_app
      app.command "add", Int32, Int32 do |a, b|
        a + b
      end
      error = expect_raises(CrystKit::Core::IPCError) do
        app.router.invoke_command("add", JSON.parse(%({"a":3,"b":4})))
      end
      error.code.should eq("VALIDATION_ERROR")
    end
    it "rejects the wrong number of positional arguments" do
      app = make_app
      app.command "add", Int32, Int32 do |a, b|
        a + b
      end
      error = expect_raises(CrystKit::Core::IPCError) do
        app.router.invoke_command("add", JSON.parse(%([3])))
      end
      error.code.should eq("VALIDATION_ERROR")
    end
    it "coerces hash return values" do
      app = make_app
      app.command "info" do
        {"answer" => 42, "ok" => true}
      end
      result = app.router.invoke_command("info", JSON.parse(%({})))
      result["answer"].as_i.should eq(42)
      result["ok"].as_bool.should be_true
    end
    it "coerces array return values" do
      app = make_app
      app.command "nums" do
        [1, 2, 3]
      end
      result = app.router.invoke_command("nums", JSON.parse(%({})))
      result.as_a.map(&.as_i).should eq([1, 2, 3])
    end
    it "subscribes and dispatches events through the app surface" do
      app = make_app
      received = [] of String
      app.on("hello") { |payload| received << payload.as_s }
      app.emit("hello", JSON::Any.new("world"))
      received.should eq(["world"])
    end
    it "allows frontend-originated events registered through the app surface" do
      app = make_app
      received = [] of JSON::Any
      app.on("frontend:ping") { |payload| received << payload }
      app.router.emit_frontend_event("frontend:ping", JSON.parse(%({"message":"ping"})), CrystKit::IPC::Context.new(frontend: true))
      received.should eq([JSON.parse(%({"message":"ping"}))])
    end
    it "auto-coerces emit payloads" do
      app = make_app
      received = [] of Int32
      app.on("count") { |payload| received << payload.as_i }
      app.emit("count", 7)
      received.should eq([7])
    end
    it "exposes structured command envelopes through the router" do
      app = make_app
      app.command "greet", String do |name|
        "Hello, #{name}"
      end
      envelope = app.router.invoke_envelope("greet", JSON.parse(%("World")))
      envelope.ok?.should be_true
      envelope.value.not_nil!.as_s.should eq("Hello, World")
    end
  end
  describe "#async" do
    it "registers an async command executable via the bridge" do
      app = make_app
      app.async "compute.sum" do
        42
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "compute.sum", JSON::Any.new(nil))
      envelope.ok?.should be_true
      envelope.value.not_nil!.as_i.should eq(42)
    end
    it "registers an async command with a typed input parameter via the bridge" do
      app = make_app
      app.async "echo.name", String do |name, _cancel|
        "Hello, #{name}"
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "echo.name", JSON::Any.new("World"))
      envelope.ok?.should be_true
      envelope.value.not_nil!.as_s.should eq("Hello, World")
    end
    it "returns self for chaining" do
      app = make_app
      result = app.async("noop") { 0 }
      result.should be(app)
    end
    it "coerces hash return values from async handlers via the bridge" do
      app = make_app
      app.async "info.async" do
        {"status" => "ok", "count" => 3}
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "info.async", JSON::Any.new(nil))
      envelope.ok?.should be_true
      envelope.value.not_nil!["status"].as_s.should eq("ok")
      envelope.value.not_nil!["count"].as_i.should eq(3)
    end
    it "passes a cancellation token to the handler via the bridge" do
      app = make_app
      token_seen = [] of Bool
      app.async "check.token", String do |_input, cancel|
        token_seen << cancel.cancelled?
        "ok"
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "check.token", JSON::Any.new("test"))
      envelope.ok?.should be_true
      envelope.value.not_nil!.as_s.should eq("ok")
      token_seen.should eq([false])
    end
    it "enforces policy on async commands invoked through the bridge" do
      app = make_app
      called = false
      app.router.policy_resolver.register_override(
        "secure.async",
        CrystKit::IPC::CommandPolicy.new(capability: "secret"),
      )
      app.async "secure.async" do
        called = true
        "done"
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router, CrystKit::IPC::Context.new(security: CrystKit::Security::Context.new))
      envelope = invoke_via_bridge(host, "secure.async", JSON::Any.new(nil))
      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("CAPABILITY_DENIED")
      called.should be_false
    end
    it "returns COMMAND_NOT_FOUND for unregistered async commands via the bridge" do
      app = make_app
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "nope.nope", JSON::Any.new(nil))
      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("COMMAND_NOT_FOUND")
    end
    it "times out and returns a TIMEOUT envelope via the bridge" do
      app = make_app
      app.async "slow.forever", timeout: 100.milliseconds do
        sleep 2.seconds
        "done"
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "slow.forever", JSON::Any.new(nil))
      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("TIMEOUT")
    end
    it "uses the router default timeout when none is specified" do
      app = make_app
      app.router.command_timeout = 100.milliseconds
      app.async "slow.default" do
        sleep 2.seconds
        "done"
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "slow.default", JSON::Any.new(nil))
      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("TIMEOUT")
    end
    it "completes successfully when timeout is generous" do
      app = make_app
      app.async "slow.ok", timeout: 5.seconds do
        sleep 50.milliseconds
        42
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "slow.ok", JSON::Any.new(nil))
      envelope.ok?.should be_true
      envelope.value.not_nil!.as_i.should eq(42)
    end
    it "coexists with sync commands registered via #command" do
      app = make_app
      app.command "sync.hello", String do |name|
        "Hi, #{name}"
      end
      app.async "async.world", String do |name, _cancel|
        "Bye, #{name}"
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      sync_env = invoke_via_bridge(host, "sync.hello", JSON::Any.new("Crystal"))
      async_env = invoke_via_bridge(host, "async.world", JSON::Any.new("Crystal"))
      sync_env.ok?.should be_true
      sync_env.value.not_nil!.as_s.should eq("Hi, Crystal")
      async_env.ok?.should be_true
      async_env.value.not_nil!.as_s.should eq("Bye, Crystal")
    end
    it "delivers async handler exceptions as error envelopes via the bridge" do
      app = make_app
      app.async "fail.async" do
        raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "fail.async", JSON::Any.new(nil))
      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("BOOM")
    end
    it "registers an async command with 2 typed parameters via the bridge" do
      app = make_app
      app.async "async.add", Int32, Int32 do |a, b, _cancel|
        a + b
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "async.add", JSON.parse(%([3, 4])))
      envelope.ok?.should be_true
      envelope.value.not_nil!.as_i.should eq(7)
    end
    it "registers an async command with 3 typed parameters via the bridge" do
      app = make_app
      app.async "async.concat", String, String, String do |a, b, c, _cancel|
        "#{a}#{b}#{c}"
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "async.concat", JSON.parse(%(["foo", "bar", "baz"])))
      envelope.ok?.should be_true
      envelope.value.not_nil!.as_s.should eq("foobarbaz")
    end
    it "passes the cancellation token as the last argument to multi-arg async" do
      app = make_app
      token_seen = [] of Bool
      app.async "async.token3", String, Int32 do |_s, _n, cancel|
        token_seen << cancel.cancelled?
        "ok"
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "async.token3", JSON.parse(%(["hi", 42])))
      envelope.ok?.should be_true
      envelope.value.not_nil!.as_s.should eq("ok")
      token_seen.should eq([false])
    end
    it "rejects wrong number of arguments for multi-arg async" do
      app = make_app
      app.async "async.add2", Int32, Int32 do |a, b, _cancel|
        a + b
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "async.add2", JSON.parse(%([3])))
      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("VALIDATION_ERROR")
    end
    it "supports timeout on multi-arg async via the bridge" do
      app = make_app
      app.async "async.slow2", Int32, Int32, timeout: 100.milliseconds do |_a, _b, _cancel|
        sleep 2.seconds
        99
      end
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(app.router)
      envelope = invoke_via_bridge(host, "async.slow2", JSON.parse(%([1, 2])))
      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("TIMEOUT")
    end
  end
  describe "plugin registration" do
    it "registers default-constructible plugins by class" do
      app = make_app
      app.plugin(CrystKit::Plugins::SystemInfo)
      app.get_plugin?("system_info").should be_a(CrystKit::Plugins::SystemInfo)
    end
    it "wires a plugin's IPC commands automatically" do
      app = make_app
      app.grant("clipboard:read", "clipboard:write")
      app.plugin(CrystKit::Plugins::Clipboard.new)
      app.router.registered_commands.should contain("clipboard.read_text")
      app.router.registered_commands.should contain("clipboard.write_text")
      app.router.registered_commands.should contain("clipboard.read_html")
      app.router.registered_commands.should contain("clipboard.write_html")
    end
    it "rejects duplicate plugin identifiers" do
      app = make_app
      app.plugin(CrystKit::Plugins::SystemInfo.new)
      expect_raises(CrystKit::Core::PluginError, /already registered/) do
        app.plugin(CrystKit::Plugins::SystemInfo.new)
      end
    end
    it "supports lookup by class via find_plugin" do
      app = make_app
      app.plugin(CrystKit::Plugins::SystemInfo.new)
      found = app.find_plugin?(CrystKit::Plugins::SystemInfo)
      found.should_not be_nil
    end
    it "supports lookup by id via get_plugin" do
      app = make_app
      app.plugin(CrystKit::Plugins::SystemInfo.new)
      app.get_plugin?("system_info").should_not be_nil
      app.get_plugin?("missing").should be_nil
    end
    it "makes plugin commands available through router envelopes" do
      app = make_app
      app.plugin(CrystKit::Plugins::SystemInfo.new)
      envelope = app.router.invoke_envelope("system_info.os", JSON.parse(%({})))
      envelope.ok?.should be_true
      envelope.value.should_not be_nil
    end
    it "declares frontend_events so the frontend can emit them" do
      app = make_app
      plugin = FrontendEventTestPlugin.new
      app.plugin(plugin)
      app.router.emit_frontend_event("fe.test.ping", JSON::Any.new(nil),
        CrystKit::IPC::Context.new(frontend: true))
    end
    it "does not declare backend events as frontend-emittable" do
      app = make_app
      plugin = FrontendEventTestPlugin.new
      app.plugin(plugin)
      expect_raises(CrystKit::Core::SecurityError, "not declared as frontend-emittable") do
        app.router.emit_frontend_event("fe.test.broadcast", JSON::Any.new(nil),
          CrystKit::IPC::Context.new(frontend: true))
      end
    end
  end
  describe "FS plugin commands" do
    it "registers all expected fs commands" do
      app = make_app
      app.grant("fs:read", "fs:write", "fs:delete")
      app.plugin(CrystKit::Plugins::FS.new)
      cmds = app.router.registered_commands
      %w(fs.read_text fs.write_text fs.list_dir fs.exists fs.metadata
        fs.remove_file fs.remove_dir fs.create_dir fs.copy fs.move
        fs.read_binary fs.write_binary).each do |c|
        cmds.should contain(c)
      end
    end
    it "round-trips read_text and write_text via IPC" do
      SpecHelpers.with_temp_dir do |dir|
        app = make_app(dir)
        app.grant("fs:read", "fs:write")
        app.scopes.persist(Path[dir], CrystKit::Security::Permission::Write)
        app.plugin(CrystKit::Plugins::FS.new)
        target = Path[dir] / "hello.txt"
        app.router.invoke_command("fs.write_text", JSON.parse(%({"path":#{target.to_s.to_json},"content":"hi"})))
        result = app.router.invoke_command("fs.read_text", JSON.parse(%({"path":#{target.to_s.to_json}})))
        result.as_s.should eq("hi")
      end
    end
    it "fs:exists returns true for an existing file" do
      SpecHelpers.with_temp_file("data") do |file|
        app = make_app
        app.grant("fs:read")
        app.scopes.persist(Path[file].parent, CrystKit::Security::Permission::Read)
        app.plugin(CrystKit::Plugins::FS.new)
        result = app.router.invoke_command("fs.exists", JSON.parse(%({"path":#{file.to_json}})))
        result.as_bool.should be_true
      end
    end
  end
  describe "Store plugin commands" do
    it "registers all store commands" do
      app = make_app
      app.plugin(CrystKit::Plugins::Store.new)
      cmds = app.router.registered_commands
      %w(store.get store.set store.delete store.keys store.has store.clear store.size).each do |c|
        cmds.should contain(c)
      end
    end
    it "round-trips set and get through IPC" do
      app = make_app
      app.plugin(CrystKit::Plugins::Store.new)
      app.router.invoke_command("store.set",
        JSON.parse(%(["main","theme","dark"])))
      result = app.router.invoke_command("store.get",
        JSON.parse(%(["main","theme"])))
      result.as_s.should eq("dark")
    end
    it "store:has reflects presence" do
      app = make_app
      app.plugin(CrystKit::Plugins::Store.new)
      app.router.invoke_command("store.set",
        JSON.parse(%(["x","k","v"])))
      result = app.router.invoke_command("store.has",
        JSON.parse(%(["x","k"])))
      result.as_bool.should be_true
    end
  end
  describe "SystemInfo plugin commands" do
    it "exposes os, arch, hostname, cpu, memory, home_dir" do
      app = make_app
      app.plugin(CrystKit::Plugins::SystemInfo.new)
      cmds = app.router.registered_commands
      %w(system_info.os system_info.arch system_info.hostname
        system_info.cpu system_info.memory system_info.home_dir).each do |c|
        cmds.should contain(c)
      end
    end
    it "system_info:os returns a non-empty name" do
      app = make_app
      app.plugin(CrystKit::Plugins::SystemInfo.new)
      result = app.router.invoke_command("system_info.os", JSON.parse(%({})))
      result["name"].as_s.should_not be_empty
    end
  end
  describe "Notifications plugin" do
    it "registers the show command" do
      app = make_app
      app.plugin(CrystKit::Plugins::Notifications.new)
      app.router.registered_commands.should contain("notification.show")
      app.router.registered_commands.should contain("notification.request_permission")
    end
  end
  describe "External, HTTP, Dialog plugins" do
    it "register their respective commands" do
      app = make_app
      app.plugin(CrystKit::Plugins::External.new)
      app.plugin(CrystKit::Plugins::HTTP.new)
      app.plugin(CrystKit::Plugins::Dialog.new)
      cmds = app.router.registered_commands
      cmds.should contain("external.open_url")
      cmds.should contain("external.open_file")
      cmds.should contain("http.get")
      cmds.should contain("http.post")
      cmds.should contain("http.put")
      cmds.should contain("http.delete")
      cmds.should contain("http.patch")
      cmds.should contain("dialog.open_file")
      cmds.should contain("dialog.open_files")
      cmds.should contain("dialog.save_file")
      cmds.should contain("dialog.select_folder")
    end
  end
  describe "all built-in plugins together" do
    it "registers without conflicts when added in one app" do
      app = make_app
      app.grant("fs:read", "fs:write", "fs:delete",
        "clipboard:read", "clipboard:write",
        "dialog:open", "dialog:save",
        "notification:show",
        "external:open",
        "http:request")
      app.plugin(CrystKit::Plugins::FS.new)
      app.plugin(CrystKit::Plugins::Clipboard.new)
      app.plugin(CrystKit::Plugins::Dialog.new)
      app.plugin(CrystKit::Plugins::Notifications.new)
      app.plugin(CrystKit::Plugins::SystemInfo.new)
      app.plugin(CrystKit::Plugins::External.new)
      app.plugin(CrystKit::Plugins::Store.new)
      app.plugin(CrystKit::Plugins::HTTP.new)
      app.router.registered_commands.size.should be > 30
    end
  end
end
describe "IPC JS bridge" do
  it "delivers a frontend invoke through the IPC core round-trip" do
    app = make_app
    app.command "echo", String do |text|
      text.upcase
    end
    payload = JSON.parse(%("hello"))
    result = app.router.invoke_command("echo", payload)
    result.as_s.should eq("HELLO")
  end
  it "delivers a backend event through the bus to a frontend listener stub" do
    app = make_app
    received = [] of String
    app.on("server:tick") { |payload| received << payload["msg"].as_s }
    app.emit("server:tick", JSON.parse(%({"msg":"ok"})))
    received.should eq(["ok"])
  end
end

private def make_app(dir : String? = nil) : CrystKit::App
  storage = dir ? Path[dir] : Path[File.tempname("webview_app_spec")]
  config = CrystKit::AppConfig.new(
    identifier: "test.app.#{Random.rand(100_000)}",
    storage_dir: storage,
  )
  CrystKit::App.new(config)
end

describe CrystKit::App do
  it "exposes a public asset_fetcher after construction" do
    config = CrystKit::AppConfig.new
    app = CrystKit::App.new(config)
    app.asset_fetcher.should be_a(CrystKit::Features::AssetFetcher)
  end
  it "exposes a public asset_source (nil when no vpak/frontend dir)" do
    config = CrystKit::AppConfig.new
    app = CrystKit::App.new(config)
    app.asset_source.should be_nil
  end
  it "wires asset_fetcher into App#tray" do
    config = CrystKit::AppConfig.new
    app = CrystKit::App.new(config)
    app.capabilities.grant("tray")
    tray = app.tray { |t| }
    tray.should be_a(CrystKit::Features::SystemTray)
    tray.created?.should be_false
  end
  it "wires asset_fetcher into App#notifications" do
    config = CrystKit::AppConfig.new
    app = CrystKit::App.new(config)
    app.capabilities.grant("notification:show")
    notifs = app.notifications { |n| }
    notifs.should be_a(CrystKit::Features::Notifications)
  end
end

enum Color
  Red
  Blue
end

struct Point
  include JSON::Serializable
  property x : Int32
  property y : Int32

  def initialize(@x : Int32, @y : Int32)
  end
end

class NonSerializable
  def to_json(builder : JSON::Builder)
    raise "I refuse to serialize"
  end
end

describe CrystKit::App, "#coerce_to_json" do
  app = CrystKit::App.new
  it "passes JSON::Any through unchanged" do
    value = JSON::Any.new(42)
    app.coerce_to_json(value).should eq value
  end
  it "coerces a String to a JSON string" do
    app.coerce_to_json("hello").should eq JSON::Any.new("hello")
  end
  it "coerces an Int32 to a JSON number" do
    result = app.coerce_to_json(42)
    result.raw.should eq 42
  end
  it "coerces a Bool to a JSON bool" do
    app.coerce_to_json(true).raw.should be_true
  end
  it "coerces nil to JSON null" do
    app.coerce_to_json(nil).raw.should be_nil
  end
  it "coerces Array(String) to a JSON array" do
    result = app.coerce_to_json(["a", "b"])
    result.raw.should be_a(Array(JSON::Any))
    arr = result.raw.as(Array(JSON::Any))
    arr.size.should eq 2
    arr[0].raw.should eq "a"
    arr[1].raw.should eq "b"
  end
  it "coerces Hash(String, Int32) to a JSON object" do
    result = app.coerce_to_json({"x" => 1})
    result.raw.should be_a(Hash(String, JSON::Any))
    result.raw.as(Hash(String, JSON::Any))["x"].raw.should eq 1
  end
  it "coerces Bytes to a base64-encoded JSON string" do
    result = app.coerce_to_json(Bytes[72_i8, 105_i8])
    result.raw.should be_a(String)
    decoded = Base64.decode(result.raw.as(String))
    decoded.should eq Bytes[72_i8, 105_i8]
    String.new(decoded).should eq "Hi"
  end
  it "coerces an Enum to its string name" do
    app.coerce_to_json(Color::Blue).should eq JSON::Any.new("Blue")
  end
  it "narrows UInt64 within Int64 range to Int64" do
    result = app.coerce_to_json(42_u64)
    result.raw.should eq 42
    result.raw.should be_a(Int64)
  end
  it "degrades UInt64 exceeding Int64::MAX to Float64" do
    result = app.coerce_to_json(UInt64::MAX)
    result.raw.should be_a(Float64)
  end
  it "keeps Int64::MAX (as UInt64) as Int64" do
    result = app.coerce_to_json(UInt64.new(Int64::MAX))
    result.raw.should be_a(Int64)
    result.raw.should eq Int64::MAX
  end
  it "coerces a JSON::Serializable struct to a JSON::Any with the right fields" do
    result = app.coerce_to_json(Point.new(3, 4))
    result.raw.should be_a(Hash(String, JSON::Any))
    hash = result.raw.as(Hash(String, JSON::Any))
    hash["x"].raw.should eq 3
    hash["y"].raw.should eq 4
  end
  it "raises Core::IPCError for non-serializable types" do
    expect_raises(CrystKit::Core::IPCError) do
      app.coerce_to_json(NonSerializable.new)
    end
  end
end
