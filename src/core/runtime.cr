require "log"
require "native_desktop"
require "../ipc/router"
require "../ipc/policy"
require "../security/context"
require "../plugins/registry"
require "../platform/services"
require "../app/app_config"
require "./window_registry"
require "./lifecycle"
require "../features/menu"
require "../features/notifications"
require "../features/shortcuts"
require "../features/taskbar_progress"
require "../features/tray"
require "../features/file_associations"
require "../features/activations"
require "./future"
require "../state/registry"

module CrystKit
  # The runtime core: window registry, runtime, lifecycle, and window
  # abstractions. Owned by `App` and not usually instantiated directly.
  module Core
    # Acceptable feature-target specifiers: `:primary`, `:all`, a window
    # id or label (`String`), or a `Core::Window` instance.
    alias FeatureTarget = Symbol | String | Window

    # :nodoc:
    private struct MenuBarBinding
      getter menu_bar : Features::MenuBar
      getter target : FeatureTarget

      def initialize(@menu_bar : Features::MenuBar, @target : FeatureTarget)
      end
    end

    # Owns all mutable application runtime state.
    #
    # `App` is the public API surface; `Runtime` is the state container
    # that holds every mutable service the app touches — the IPC
    # `Router`, `Security::Context`, `WindowRegistry`,
    # `Plugin::Registry`, `Platform::Services`, `Lifecycle`, and the
    # app-owned native feature objects (`MenuBar`, `SystemTray`,
    # `GlobalShortcuts`, `TaskbarProgress`, `Notifications`).
    #
    # `App` composes a `Runtime` and delegates to it. Moving state into
    # `Runtime` keeps `App` a thin facade: the public methods stay on
    # `App`, the plumbing lives on `Runtime`.
    class Runtime
      # :nodoc:
      Log = ::Log.for(self)

      # The configuration this runtime was constructed from.
      getter config : AppConfig

      # The IPC command and event router.
      getter router : IPC::Router

      # The security context for capability and scope checks.
      getter security : Security::Context

      # The registry owning every open window.
      getter windows : WindowRegistry

      # The plugin registry.
      getter plugins : Plugin::Registry

      # The platform services facade.
      getter platform : Platform::Services

      # The lifecycle manager.
      getter lifecycle : Lifecycle

      # The app-owned menu bar, if one has been configured.
      getter menu_bar : Features::MenuBar?

      # The app-owned system tray, or `nil` if none has been configured.
      getter tray : Features::SystemTray?

      # The app-owned global shortcuts registry, or `nil`.
      getter shortcuts : Features::GlobalShortcuts?

      # The app-owned taskbar-progress controller, or `nil`.
      getter taskbar_progress : Features::TaskbarProgress?

      # The app-owned notifications facade, or `nil`.
      getter notifications : Features::Notifications?

      # The app-owned file-association registry, or `nil`.
      getter file_associations : Features::FileAssociations?

      # Process-wide URL, file-open, and second-instance activation stream.
      getter activations : Features::Activations

      # The app-owned frontend-reactive state registry.
      getter state : State::Registry

      # Callback used by the app facade to bridge state patches to
      # frontend windows. The runtime still emits patches on the backend
      # router even when this is unset, which keeps state behavior testable
      # without a native window.
      property state_frontend_dispatcher : Proc(JSON::Any, Nil)?

      # Optional test hook that intercepts `App#bridge_to_frontend` events
      # (the path backend events take to the JS bridge). When set, `App`
      # calls this instead of evaluating JS in native windows, which lets
      # `CrystKit::Test::FakeFrontend` capture emits without entering the
      # run loop. `nil` in production — the real bridge runs only when
      # `running?` is true.
      property frontend_event_dispatcher : Proc(String, JSON::Any, ::CrystKit::Core::Window?, Nil)?

      # Callback fired when the primary window is created and IPC is
      # ready. Set by `App#on_ready`.
      property on_ready : Proc(Window, Nil)?

      # App-wide vetoable shutdown interceptor set by `App#on_before_quit`.
      # The handler returns `true` / `false` synchronously, or a
      # `Future(Bool)` whose resolution the quit path awaits. A `nil` or
      # truthy result allows the quit; a `false` (or an unresolved future
      # when *before_quit_timeout* elapses) cancels it and leaves the run
      # loop alive.
      property before_quit_handler : Proc(Bool | ::CrystKit::Future(Bool))?

      # Maximum time `App#quit` waits for an async `before_quit_handler`
      # to resolve before treating it as a veto. `nil` waits indefinitely.
      property before_quit_timeout : Time::Span?

      @menu_bar_bindings : Array(MenuBarBinding)
      @shutdown = Atomic(Bool).new(false)

      # Creates a runtime from *config* and the required services.
      #
      # *router* and *security* are required; all other services default
      # to fresh instances. The constructor also performs one-time
      # initialization: creates the storage directory, captures the main
      # fiber for `MainThread`, clears stale scopes, loads the
      # capabilities manifest, and registers IPC policy overrides from
      # the app config.
      def initialize(
        @config : AppConfig,
        @router : IPC::Router,
        @security : Security::Context,
        @windows = WindowRegistry.new,
        plugins : Plugin::Registry? = nil,
        @platform = Platform::Services.new,
        @lifecycle = Lifecycle.new,
      )
        @plugins = plugins || Plugin::Registry.new(@router)
        @menu_bar = nil
        @menu_bar_bindings = [] of MenuBarBinding
        @tray = nil
        @shortcuts = nil
        @taskbar_progress = nil
        @notifications = nil
        @file_associations = nil
        @activations = Features::Activations.new
        @on_ready = nil
        @before_quit_handler = nil
        @before_quit_timeout = nil
        @state_frontend_dispatcher = nil
        @frontend_event_dispatcher = nil
        @state = State::Registry.new(->(change : State::Change) {
          payload = change.to_json_any
          @router.emit_event("__crystkit.state.patch", payload)
          @state_frontend_dispatcher.try(&.call(payload))
        })
        ensure_storage_dir
        ::CrystKit::Core::MainThread.capture_main_fiber
        # Spawn background fibers (IPC handlers, monitors, servers, watchers) into a separate `Parallel` execution context so they never land on the main thread, which is blocked by the webview's native event loop.
        ::CrystKit::Core::Fibers.start(::CrystKit::Core::Fibers.default_max_workers)
        @security.scopes.clear
        load_capabilities_manifest
        register_ipc_policy_overrides
        register_state_commands
      end

      # :nodoc:
      def menu_bar=(menu_bar : Features::MenuBar) : Nil
        set_menu_bar(menu_bar, :primary)
      end

      # :nodoc:
      def tray=(tray : Features::SystemTray) : Nil
        @tray = tray
      end

      # :nodoc:
      def shortcuts=(shortcuts : Features::GlobalShortcuts) : Nil
        @shortcuts = shortcuts
      end

      # :nodoc:
      def taskbar_progress=(taskbar_progress : Features::TaskbarProgress) : Nil
        @taskbar_progress = taskbar_progress
      end

      # :nodoc:
      def notifications=(notifications : Features::Notifications) : Nil
        @notifications = notifications
      end

      # :nodoc:
      def file_associations=(file_associations : Features::FileAssociations) : Nil
        @file_associations = file_associations
      end

      # :nodoc:
      def set_menu_bar(menu_bar : Features::MenuBar, target : FeatureTarget) : Features::MenuBar
        @menu_bar = menu_bar
        @menu_bar_bindings.reject! { |binding| binding.target == target }
        binding = MenuBarBinding.new(menu_bar, target)
        @menu_bar_bindings << binding
        apply_menu_bar_binding(binding)
        menu_bar
      end

      # :nodoc:
      def apply_menu_bar_bindings(window : Window) : Nil
        @menu_bar_bindings.each do |binding|
          next if binding.menu_bar.requires_running_event_loop? && !@lifecycle.running?
          install_menu_bar(binding.menu_bar, window) if target_matches_window?(binding.target, window)
        end
      end

      # Shuts down all runtime state: stops new shortcut input, executes
      # lifecycle hooks, cleans up plugins and native features, destroys every
      # window, and clears the dispatch registries. Exceptions during teardown
      # are logged and do not prevent subsequent steps.
      def shutdown : Nil
        return unless @shutdown.compare_and_set(false, true)
        quietly("shortcuts") { @shortcuts.try(&.stop_listening) }
        # Stop application-owned workers while their plugin/native resources
        # are still valid. A shutdown hook may close a channel that wakes a
        # background fiber immediately; destroying the tray or a window first
        # lets that fiber race the native teardown.
        quietly("lifecycle") { @lifecycle.shutdown }
        quietly("plugins") { @plugins.cleanup_all }
        quietly("notifications") { @notifications.try(&.cleanup) }
        quietly("activations") { @activations.cleanup }
        quietly("taskbar") { @taskbar_progress.try(&.cleanup) }
        quietly("tray") { @tray.try(&.destroy) }
        quietly("windows") { @windows.destroy_all }
        quietly("Fibers.stop") { ::CrystKit::Core::Fibers.stop }
        quietly("MainThread.clear") { ::CrystKit::Core::MainThread.clear }
        quietly("NativeDesktop.detach") { ::NativeDesktop::Runtime.detach }
      end

      # :nodoc:
      private def apply_menu_bar_binding(binding : MenuBarBinding) : Nil
        return if binding.menu_bar.requires_running_event_loop? && !@lifecycle.running?
        case target = binding.target
        when Symbol
          case target
          when :all
            @windows.all.each { |window| install_menu_bar(binding.menu_bar, window) }
          when :primary
            @windows.primary.try { |window| install_menu_bar(binding.menu_bar, window) }
          else
            raise ArgumentError.new("Unsupported feature target :#{target}")
          end
        when String
          @windows.find?(target).try { |window| install_menu_bar(binding.menu_bar, window) }
        when Window
          install_menu_bar(binding.menu_bar, target)
        end
      end

      # :nodoc:
      private def target_matches_window?(target : FeatureTarget, window : Window) : Bool
        case target
        when Symbol
          target == :all || (target == :primary && @windows.primary == window)
        when String
          window.id == target || window.label == target
        when Window
          window == target
        else
          false
        end
      end

      # :nodoc:
      private def install_menu_bar(menu_bar : Features::MenuBar, window : Window) : Nil
        menu_bar.install(window.window)
      end

      private def quietly(label : String, &)
        yield
      rescue ex
        Log.error(exception: ex) { "Shutdown step '#{label}' failed" }
      end

      # :nodoc:
      private def ensure_storage_dir
        Dir.mkdir_p(@config.storage_dir.to_s)
      rescue ex
        raise Error.new(
          "Could not create storage dir #{@config.storage_dir}: #{ex.message}",
          code: "STORAGE_DIR_FAILED",
        )
      end

      # :nodoc:
      private def load_capabilities_manifest
        manifest_path = @config.capabilities_manifest
        return unless manifest_path

        # If the configured path exists, use it (dev mode — path from source)
        if File.exists?(manifest_path.to_s)
          manifest = @security.load_manifest(manifest_path)
          Log.info { "Loaded #{manifest.capabilities.size} capabilities from #{manifest_path}" }
          return
        end

        # Production fallback: look for capabilities.json next to the
        # binary or in resources/ (staged by the bundler)
        exe_dir = File.dirname(File.expand_path(Process.executable_path || Dir.current))
        candidates = [
          File.join(exe_dir, "capabilities.json"),
          File.join(exe_dir, "resources", "capabilities.json"),
        ]

        found = candidates.find { |c| File.exists?(c) }
        if found
          manifest = @security.load_manifest(Path[found])
          Log.info { "Loaded #{manifest.capabilities.size} capabilities from #{found}" }
        else
          Log.warn { "Capabilities manifest not found at #{manifest_path} or in resources/" }
        end
      end

      # :nodoc:
      private def register_ipc_policy_overrides
        @config.ipc.commands.each do |command, override|
          @router.policy_resolver.register_override(command, ipc_policy_from_override(command, override))
        end
      end

      # :nodoc:
      private def register_state_commands : Nil
        @router.register_command("__crystkit.state.attach", ->(params : JSON::Any) {
          name = params.as_s? || params["name"]?.try(&.as_s) || raise Core::IPCError.new(
            "Expected state slice name",
            code: "VALIDATION_ERROR",
          )

          slice = @state.find?(name) || raise Core::IPCError.new(
            "State slice '#{name}' is not registered",
            code: "STATE_NOT_FOUND",
          )

          slice.attach_payload
        })
      end

      # :nodoc:
      private def ipc_policy_from_override(command : String, override : ::CrystKit::IPCCommandOverride) : IPC::CommandPolicy
        capability = override.capability
        return IPC::CommandPolicy.public unless capability || override.resource

        resources = [] of IPC::ResourceRule
        if resource = override.resource
          resource_capability = capability || raise ValidationError.new(
            "IPC command override '#{command}' declares a resource without a capability",
            field: "ipc.commands.#{command}.capability",
          )
          resources << IPC::ResourceRule.new(
            resource_capability,
            ipc_resource_kind(command, override.resource_kind),
            resource,
            ipc_resource_permission(command, override.permission),
          )
        end

        IPC::CommandPolicy.new(capability: capability, resources: resources)
      end

      # :nodoc:
      private def ipc_resource_kind(command : String, value : String?) : IPC::ResourceKind
        case value.try(&.downcase)
        when nil, "resource"
          IPC::ResourceKind::Resource
        when "path"
          IPC::ResourceKind::Path
        else
          raise ValidationError.new(
            "Unsupported IPC resource kind '#{value}' for '#{command}'",
            field: "ipc.commands.#{command}.resource_kind",
          )
        end
      end

      # :nodoc:
      private def ipc_resource_permission(command : String, value : String?) : IPC::ResourcePermission?
        case value.try(&.downcase)
        when nil
          nil
        when "read"
          IPC::ResourcePermission::Read
        when "write"
          IPC::ResourcePermission::Write
        when "execute"
          IPC::ResourcePermission::Execute
        else
          raise ValidationError.new(
            "Unsupported IPC resource permission '#{value}' for '#{command}'",
            field: "ipc.commands.#{command}.permission",
          )
        end
      end
    end
  end
end
