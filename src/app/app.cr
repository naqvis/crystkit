require "json"
require "log"
require "base64"
require "uri"
require "../crystkit"
require "../core/native_window"
require "../core/window_factory"
require "../core/window_registry"
require "../core/runtime"
require "../core/cancellation_token"
require "./app_config"
require "../ipc/router"
require "../ipc/channel"
require "../ipc/js_bridge"
require "../security/capability"
require "../security/scope"
require "../security/context"
require "../plugins/base"
require "../core/errors"
require "../features/custom_protocol"
require "../features/asset_loader"
require "../features/asset_fetcher"
require "../features/menu"
require "../features/notifications"
require "../features/shortcuts"
require "../features/taskbar_progress"
require "../features/tray"
require "../features/file_associations"

module CrystKit
  # The composition root of a CrystKit application: ties together webview
  # windows, IPC, capabilities, scopes, and plugins.
  #
  # Construct an `App` from an `AppConfig` (or use `.run` for a one-shot
  # builder block), register plugins and IPC commands, create windows,
  # then call `#run` to block until the primary window closes; `#shutdown`
  # runs automatically afterwards.
  #
  # There are two ways to register IPC commands:
  #
  # * `#command` — **synchronous**. The handler runs inline on the
  #   webview's thread (the same thread that runs the native event loop)
  #   and its return value is sent back immediately. Use this for fast,
  #   in-memory work (lookups, transforms, state reads) and for any
  #   handler that calls framework OS features directly (`FileDialog`,
  #   window manipulation, tray, menus) — those features are already on
  #   the right thread.
  # * `#async` — **asynchronous**. The handler runs on its own fiber with
  #   a real `select` timeout, so the UI thread stays responsive even when
  #   the handler does blocking I/O (database queries, HTTP requests,
  #   large file reads). A `CancellationToken` is passed to the handler
  #   so it can bail out early when the timeout fires. Framework OS
  #   features called from an async handler are automatically routed onto
  #   the webview's thread via `Core::MainThread` — the developer does
  #   not reason about threading.
  #
  # Both produce the same frontend API: `await ipc.invoke("name", ...)`.
  # The frontend does not know or care which variant was used.
  #
  # ```
  # CrystKit::App.run do |app|
  #   app.plugin CrystKit::Plugins::FS.new
  #
  #   # Sync — fast, in-memory
  #   app.command "greet", String do |name|
  #     "Hello, #{name}"
  #   end
  #
  #   # Async — blocking I/O with a 10-second timeout
  #   app.async "db.query", String, timeout: 10.seconds do |sql, cancel|
  #     DB.query(sql).to_a
  #   end
  #
  #   app.window(title: "My App", html: "<h1>Hi</h1>")
  # end
  # ```
  class App
    # :nodoc:
    Log = ::Log.for(self)

    ASSET_SCHEME = "crystkit"

    def self.asset_origin : String
      {% if flag?(:windows) %}
        "https://#{ASSET_SCHEME}.localhost/"
      {% else %}
        "#{ASSET_SCHEME}://localhost/"
      {% end %}
    end

    # The configuration this app was constructed from.
    getter config : AppConfig

    # The runtime aggregating all mutable services (router, security,
    # windows, plugins, platform, lifecycle, app-owned features).
    getter runtime : Core::Runtime

    # The asset source backing the built-in `crystkit://` protocol, or
    # `nil` when no assets were found or the protocol is disabled.
    @asset_source : Features::AssetSource?

    @asset_fetcher : Features::AssetFetcher

    # Creates an `App` from *config* and a *platform* services facade.
    #
    # After this returns, the app is ready to register plugins, declare
    # commands, and create windows, but is not yet running — call `#run`
    # to enter the event loop.
    #
    # *platform* defaults to a fresh `Platform::Services` for the host OS.
    def initialize(
      @config = AppConfig.new,
      platform : Platform::Services = Platform::Services.new,
    )
      security = Security::Context.new(
        Security::CapabilitySystem.new,
        Security::ScopeManager.new(@config.storage_dir / "scopes.json"),
      )
      @runtime = Core::Runtime.new(@config, IPC::Router.new, security, platform: platform)
      if executable = Process.executable_path
        ::NativeDesktop.application.configure(
          ::NativeDesktop::ApplicationIdentity.new(
            @config.identifier,
            @config.name,
            Path[executable].expand,
          )
        )
      end
      @runtime.state_frontend_dispatcher = ->(payload : JSON::Any) {
        bridge_state_patch_to_frontend(payload)
      }
      @asset_fetcher = Features::AssetFetcher.new(
        http_client_factory: -> { Features::HTTPClient.new(security) }
      )
    end

    # The IPC router. Shortcut for `runtime.router`.
    def router : IPC::Router
      @runtime.router
    end

    # The security context used to authorize IPC and resource access.
    # Shortcut for `runtime.security`.
    def security : Security::Context
      @runtime.security
    end

    # The registry owning every open `Core::Window`. Shortcut for
    # `runtime.windows`.
    def window_registry : Core::WindowRegistry
      @runtime.windows
    end

    # The plugin registry hosting all registered `Plugin::Base`
    # instances. Shortcut for `runtime.plugins`.
    def plugins : Plugin::Registry
      @runtime.plugins
    end

    # Whether the app is currently inside its run loop. Shortcut for
    # `runtime.lifecycle.running?`.
    def running? : Bool
      @runtime.lifecycle.running?
    end

    # The capability system. Shortcut for `security.capabilities`.
    def capabilities : Security::CapabilitySystem
      security.capabilities
    end

    # The scope manager. Shortcut for `security.scopes`.
    def scopes : Security::ScopeManager
      security.scopes
    end

    # The asset source backing the built-in `crystkit://` protocol and
    # every native control's VFS icon lookups, or `nil` when no vpak /
    # frontend dir was found. Lazily loaded by `load_asset_source!`.
    def asset_source : Features::AssetSource?
      load_asset_source!
      @asset_source
    end

    # The app-owned `AssetFetcher` for async network icon fetches. Always
    # present after `App#initialize`; cache cleared on `#shutdown`.
    def asset_fetcher : Features::AssetFetcher
      @asset_fetcher
    end

    # Returns the app-owned menu bar, if one has been configured.
    def menu_bar : Features::MenuBar?
      @runtime.menu_bar
    end

    # Configure the primary app menu bar from a prebuilt feature object.
    def menu_bar=(menu_bar : Features::MenuBar) : Nil
      @runtime.menu_bar = menu_bar
    end

    # Build and configure an app menu bar inline.
    def menu_bar(target : Core::FeatureTarget = :primary, &block : Features::MenuBar ->) : Features::MenuBar
      menu_bar = Features::MenuBar.new
      block.call(menu_bar)
      @runtime.set_menu_bar(menu_bar, target)
    end

    # Configure an app menu bar for a specific target.
    def menu_bar(menu_bar : Features::MenuBar, target : Core::FeatureTarget = :primary) : Features::MenuBar
      @runtime.set_menu_bar(menu_bar, target)
    end

    # Returns the app-owned system tray, or `nil` if none has been
    # configured.
    def tray : Features::SystemTray?
      @runtime.tray
    end

    # Install a pre-built `SystemTray` as the app-owned tray. Destroyed
    # by `#shutdown` on exit.
    def tray=(tray : Features::SystemTray) : Nil
      @runtime.tray = tray
    end

    # Build and install a `SystemTray` inline. Returns the installed tray.
    def tray(&block : Features::SystemTray ->) : Features::SystemTray
      load_asset_source!
      tray = Features::SystemTray.new(capabilities,
        app_id: @config.identifier,
        asset_source: @asset_source,
        asset_fetcher: @asset_fetcher)
      block.call(tray)
      self.tray = tray
      tray
    end

    # Returns the app-owned global shortcuts registry, or `nil` if
    # none has been configured.
    def shortcuts : Features::GlobalShortcuts?
      @runtime.shortcuts
    end

    # Install a pre-built `GlobalShortcuts` instance as the app-owned
    # shortcuts registry. Stopped by `#shutdown` on exit.
    def shortcuts=(shortcuts : Features::GlobalShortcuts) : Nil
      @runtime.shortcuts = shortcuts
    end

    # Build and install a `GlobalShortcuts` registry inline.
    # Returns the installed registry.
    def shortcuts(&block : Features::GlobalShortcuts ->) : Features::GlobalShortcuts
      shortcuts = Features::GlobalShortcuts.new
      block.call(shortcuts)
      self.shortcuts = shortcuts
      shortcuts
    end

    # Returns the app-owned taskbar-progress controller, or `nil` if
    # none has been configured.
    def taskbar_progress : Features::TaskbarProgress?
      @runtime.taskbar_progress
    end

    # Install a pre-built `TaskbarProgress` controller.
    def taskbar_progress=(taskbar_progress : Features::TaskbarProgress) : Nil
      @runtime.taskbar_progress = taskbar_progress
      if window = window_registry.primary
        taskbar_progress.install(window.window, @config.identifier)
      end
    end

    # Build and install a `TaskbarProgress` controller inline.
    # Returns the installed controller.
    def taskbar_progress(&block : Features::TaskbarProgress ->) : Features::TaskbarProgress
      load_asset_source!
      taskbar_progress = Features::TaskbarProgress.new
      block.call(taskbar_progress)
      self.taskbar_progress = taskbar_progress
      taskbar_progress
    end

    # Returns the app-owned notifications facade, or `nil` if none has
    # been configured.
    def notifications : Features::Notifications?
      @runtime.notifications
    end

    # Install a pre-built `Notifications` facade as the app-owned
    # notification service.
    def notifications=(notifications : Features::Notifications) : Nil
      @runtime.notifications = notifications
    end

    # Build and install a `Notifications` facade inline.
    # Returns the installed facade.
    def notifications(&block : Features::Notifications ->) : Features::Notifications
      load_asset_source!
      notifications = Features::Notifications.new(capabilities,
        app_name: @config.name,
        asset_source: @asset_source,
        asset_fetcher: @asset_fetcher)
      block.call(notifications)
      self.notifications = notifications
      notifications
    end

    # The app-owned file-association registry.
    #
    # It is created lazily from `config.identifier`, `config.name`, and the
    # current executable path.
    def file_associations : Features::FileAssociations
      if associations = @runtime.file_associations
        return associations
      end

      executable = Process.executable_path
      unless executable
        raise Core::Error.new(
          "Cannot register file associations because the executable path is unavailable",
          code: "EXECUTABLE_PATH_UNAVAILABLE",
        )
      end

      associations = Features::FileAssociations.new(
        @config.identifier,
        @config.name,
        Path[executable],
        storage_file: @config.storage_dir / "file-associations.json",
      )
      @runtime.file_associations = associations
      associations
    end

    # Installs a pre-built file-association registry as the app-owned feature.
    def file_associations=(associations : Features::FileAssociations) : Nil
      @runtime.file_associations = associations
    end

    # Configures the app-owned file-association registry inline.
    def file_associations(&block : Features::FileAssociations ->) : Features::FileAssociations
      associations = file_associations
      block.call(associations)
      associations
    end

    # Returns the app-owned frontend-reactive state registry.
    def state_registry : State::Registry
      @runtime.state
    end

    # Declares a frontend-reactive state slice.
    #
    # The returned `State::Slice(T)` owns a normal Crystal value. Mutate it
    # with `State::Slice#update`; read it with `State::Slice#value`.
    # CrystKit captures the serialized before/after difference as JSON
    # Patch and updates all frontend mirrors attached with
    # `window.__CRYSTKIT_IPC__.state(name)`.
    #
    # ```
    # settings = app.state("settings", SettingsState) { SettingsState.new }
    # settings.update { |s| s.theme = "dark"; s }
    # ```
    def state(name : String, type : T.class, &block : -> T) : State::Slice(T) forall T
      state_registry.register(name, block.call)
    end

    # Returns an existing frontend-reactive state slice by name and type.
    #
    # Raises `Core::ValidationError` when the slice is missing or was
    # registered with a different value type.
    def state(name : String, type : T.class) : State::Slice(T) forall T
      state_registry.fetch(name, type)
    end

    # Returns an existing frontend-reactive state slice by name and type,
    # or `nil` when it is missing or has a different value type.
    def state?(name : String, type : T.class) : State::Slice(T)? forall T
      state_registry.fetch?(name, type)
    end

    # Returns the primary (first-created) window, or nil if no window exists yet.
    def primary_window : Core::Window?
      window_registry.primary
    end

    # Returns all windows currently owned by the App.
    def windows : Array(Core::Window)
      window_registry.all
    end

    # Hides the window identified by label (no-op if not found).
    def hide_window(label : String) : Nil
      window_registry.find?(label).try(&.hide)
    end

    # Shows the window identified by label (no-op if not found).
    def show_window(label : String) : Nil
      window_registry.find?(label).try(&.show)
    end

    # Grant one or more capabilities at the application level.
    # Returns `self` for chaining.
    #
    # ```
    # app.grant("fs", "net", "clipboard")
    # ```
    def grant(*capabilities : String) : self
      capabilities.each { |cap| security.capabilities.grant(cap) }
      self
    end

    # Register a plugin. Plugins auto-wire IPC commands and events.
    # Returns `self` for chaining.
    def plugin(plugin : Plugin::Base) : self
      id = plugin.identifier
      plugin_config = @config.plugins_config[id]? || JSON::Any.new(Hash(String, JSON::Any).new)
      ctx = Plugin::Context.new(
        app: self,
        router: router,
        security: security,
        registry: plugins,
        plugin_id: id,
        config: plugin_config,
      )
      plugins.register(plugin, ctx)
      Log.debug { "Registered plugin: #{id}" }
      self
    end

    # Register a default-constructible plugin by class.
    def plugin(plugin_type : T.class) : self forall T
      plugin(plugin_type.new)
    end

    # Look up a registered plugin by identifier. Raises if not found.
    def get_plugin(id : String) : Plugin::Base
      plugins.find(id)
    end

    # Look up a registered plugin by identifier (returns nil if not found).
    def get_plugin?(id : String) : Plugin::Base?
      plugins.find?(id)
    end

    # Get a registered plugin by class. Raises if not registered.
    def find_plugin(type : T.class) : T forall T
      plugins.find(type)
    end

    # Get a registered plugin by class. Returns nil if not registered.
    def find_plugin?(type : T.class) : T? forall T
      plugins.find?(type)
    end

    # Register a **synchronous** IPC command with no typed parameters.
    #
    # The handler runs inline on the webview's thread and its return
    # value is sent to the frontend immediately. Use `#async` instead
    # when the handler does blocking I/O (database, HTTP, file reads) —
    # a slow `#command` handler will block the UI thread for its
    # duration. Framework OS features (`FileDialog`, window
    # manipulation, tray, menus) are safe to call from `#command`
    # because the handler is already on the right thread.
    #
    # Returns `self` for chaining.
    #
    # ```
    # app.command("ping") { "pong" }
    # ```
    def command(name : String, &block : -> R) forall R
      register_command_handler(name, ->(_params : JSON::Any) {
        begin
          coerce_to_json(block.call)
        rescue ex : Core::Error
          raise ex
        rescue ex
          raise Core::IPCError.new("Command failed: #{ex.message}", code: "COMMAND_EXECUTION_ERROR")
        end
      })
    end

    # Register a **synchronous** command whose single argument is decoded
    # from the complete payload. See `#command(name, &block)` for when to
    # use `#command` vs `#async`.
    def command(name : String, input_type : T.class, &block : T -> R) forall T, R
      register_command_handler(name, ->(params : JSON::Any) {
        begin
          coerce_to_json(block.call(IPC::Router.decode(params, input_type)))
        rescue ex : Core::Error
          raise ex
        rescue ex
          raise Core::IPCError.new("Command failed: #{ex.message}", code: "COMMAND_EXECUTION_ERROR")
        end
      })
    end

    ::CrystKit.define_sync_typed_commands(2..6, "command", "register_command_handler")

    # Internal entry point: wraps a command handler for the router's JSON
    # transport.
    #
    # :nodoc:
    def register_command_handler(cmd : String, handler : Proc(::JSON::Any, JSON::Any)) : self
      router.register_command(cmd, ->(params : JSON::Any) {
        handler.call(params)
      })
      self
    end

    # Register an **asynchronous** IPC command with no typed parameters.
    #
    # The handler runs on its own fiber with a real `select` timeout — the
    # UI thread stays responsive even when the handler does blocking I/O.
    # If *timeout* elapses before the handler returns, the frontend receives
    # a `TIMEOUT` error and the handler's `CancellationToken` is set so it
    # can bail out early (cooperatively). Use `#command` for fast, in-memory
    # work that doesn't need a timeout or cancellation.
    #
    # Framework OS features (`FileDialog`, window manipulation, tray,
    # menus) are safe to call from `#async` — they are automatically
    # routed onto the webview's thread via `Core::MainThread`. The
    # developer does not reason about threading.
    #
    # *timeout* overrides the router's default `command_timeout` for this
    # command only. Returns `self` for chaining.
    #
    # ```
    # app.async("db.query", timeout: 5.seconds) { DB.query("SELECT 1").to_a }
    # ```
    def async(name : String, timeout : Time::Span? = nil, &block : -> R) forall R
      register_async_handler(name, ->(_params : JSON::Any, _token : Core::CancellationToken) {
        begin
          coerce_to_json(block.call)
        rescue ex : Core::Error
          raise ex
        rescue ex
          raise Core::IPCError.new("Async command failed: #{ex.message}", code: "COMMAND_EXECUTION_ERROR")
        end
      }, timeout: timeout)
    end

    # Register an **asynchronous** command whose single argument is decoded
    # from the complete payload. The handler also receives a
    # `CancellationToken`. See `#async(name, timeout, &block)` for the
    # sync-vs-async guidance. *timeout* overrides the router's default
    # `command_timeout` for this command only.
    def async(name : String, input_type : T.class, timeout : Time::Span? = nil,
              &block : T, Core::CancellationToken -> R) forall T, R
      register_async_handler(name, ->(params : JSON::Any, token : Core::CancellationToken) {
        begin
          coerce_to_json(block.call(IPC::Router.decode(params, input_type), token))
        rescue ex : Core::Error
          raise ex
        rescue ex
          raise Core::IPCError.new("Async command failed: #{ex.message}", code: "COMMAND_EXECUTION_ERROR")
        end
      }, timeout: timeout)
    end

    ::CrystKit.define_async_typed_commands(2..6, "async", "register_async_handler")

    # Internal entry point for async command registration.
    # :nodoc:
    def register_async_handler(cmd : String, handler : Proc(::JSON::Any, Core::CancellationToken, JSON::Any),
                               timeout : Time::Span? = nil) : self
      router.register_async_command(cmd, ->(_context : IPC::Context, params : JSON::Any, token : Core::CancellationToken) {
        handler.call(params, token)
      }, timeout: timeout)
      self
    end

    # Subscribe to an event emitted by the frontend or by other parts of
    # the app. Multiple subscribers may be attached to the same event.
    # Returns `self` for chaining.
    def on(event : String, &handler : JSON::Any -> Nil) : self
      router.declare_frontend_event(event)
      router.subscribe_event(event, handler)
      self
    end

    # Emit an event to all subscribers (including frontend listeners).
    # When *target* is given, the frontend dispatch is scoped to that
    # window only. Returns `self` for chaining.
    def emit(event : String, payload : JSON::Any, target : Core::Window? = nil) : self
      router.emit_event(event, payload, target)
      bridge_event_to_frontend(event, payload, target)
      self
    end

    # Emit an event with an arbitrary payload, coercing it to `JSON::Any`.
    # See the typed overload above. Returns `self` for chaining.
    def emit(event : String, payload, target : Core::Window? = nil) : self
      emit(event, coerce_to_json(payload), target: target)
    end

    # :nodoc:
    def bridge_event_to_frontend(event : String, payload : JSON::Any, target : Core::Window? = nil) : Nil
      bridge_to_frontend(event, payload, target)
    end

    # :nodoc:
    def bridge_state_patch_to_frontend(payload : JSON::Any) : Nil
      bridge_to_frontend("__crystkit.state.patch", payload)
    end

    # Create a window. The first registered window becomes the primary.
    #
    # *label* is an optional application-defined identifier that must
    # be unique within the registry; it is required when the loaded
    # capabilities manifest declares per-window grants (otherwise
    # `#wire_window` raises `Core::SecurityError`).
    #
    # Returns the newly created `Core::Window`.
    #
    # ```
    # app.window(title: "Main", label: "main", html: "<h1>Hello</h1>")
    # ```
    def window(
      title : String = "Window",
      width : Int32 = 800,
      height : Int32 = 600,
      hint : SizeHints = SizeHints::NONE,
      url : String? = nil,
      html : String? = nil,
      debug : Bool = false,
      label : String? = nil,
      visible : Bool = true,
    ) : Core::Window
      setup_asset_protocol if needs_asset_protocol?(url, html)
      attach_native_runtime
      wv = runtime.platform.window.create_window(title, width, height, hint, debug, label, visible)
      window = window_registry.register(wv, label, title, width, height, visible)
      wire_window(wv, window)
      @runtime.apply_menu_bar_bindings(window)
      @asset_protocol.try(&.register(wv))
      effective_url = url || (html.nil? ? default_nav_url : nil)
      runtime.platform.window.configure_content(wv, effective_url, html)
      window
    end

    # Create a window and configure it with a block. Returns the
    # configured window.
    def window(
      title : String = "Window",
      width : Int32 = 800,
      height : Int32 = 600,
      hint : SizeHints = SizeHints::NONE,
      url : String? = nil,
      html : String? = nil,
      debug : Bool = false,
      label : String? = nil,
      visible : Bool = true,
      &
    )
      window = window(title, width, height, hint, url, html, debug, label, visible)
      yield window
      window
    end

    # Create a window from `Core::WindowOptions` (full feature set: modal,
    # always-on-top, frameless, transparency, opacity, and parent-child
    # relationships).
    #
    # When *parent_label* is supplied, the window is created as a child
    # of that window. Raises `ArgumentError` if no window with that
    # label exists.
    #
    # Returns the newly created `Core::Window`.
    def window(
      options : Core::WindowOptions,
      html : String? = nil,
      parent_label : String? = nil,
      x : Int32? = nil,
      y : Int32? = nil,
    ) : Core::Window
      setup_asset_protocol if needs_asset_protocol?(options.url, html)
      attach_native_runtime
      label = options.label
      wv = if parent_label
             parent = window_registry.find?(parent_label)
             raise ArgumentError.new("Parent window '#{parent_label}' not found") unless parent
             child_options = Core::WindowOptions.new(
               width: options.width,
               height: options.height,
               hint: options.hint,
               title: options.title,
               debug: options.debug?,
               label: label,
               modal: options.modal?,
               always_on_top: options.always_on_top?,
               frameless: options.frameless?,
               transparent: options.transparent?,
               opacity: options.opacity,
               visible: options.visible?,
               minimize_to_tray: options.minimize_to_tray?,
               fullscreen: options.fullscreen?,
               x: options.x,
               y: options.y,
             )
             parent.create_child(child_options)
           else
             created = runtime.platform.window.create_window(
               options.title,
               options.width,
               options.height,
               options.hint,
               options.debug?,
               label,
               options.visible?,
             )
             created.modal = options.modal?
             created.always_on_top = options.always_on_top? if options.always_on_top?
             created.frameless = options.frameless? if options.frameless?
             created.transparent = options.transparent? if options.transparent?
             created.opacity = options.opacity unless options.opacity == 1.0
             created.minimize_to_tray = options.minimize_to_tray?
             created.fullscreen = options.fullscreen? if options.fullscreen?
             created
           end

      window = window_registry.register(wv, label, options.title, options.width, options.height, options.visible?)
      wire_window(wv, window)
      @runtime.apply_menu_bar_bindings(window)

      # Apply per-window CSP override (overrides global CSP for this window)
      if csp = options.csp
        wv.init(csp_js(csp)) unless csp.empty?
      end

      # Apply per-window preload scripts
      options.preload_scripts.each { |js| wv.init(js) }

      @asset_protocol.try(&.register(wv))
      effective_url = options.url || (html.nil? ? default_nav_url : nil)
      runtime.platform.window.configure_content(wv, effective_url, html)
      pos_x = x || options.x
      pos_y = y || options.y
      wv.move(pos_x, pos_y) if pos_x && pos_y
      window
    end

    # Create a window from `Core::WindowOptions` and configure it with a block.
    # Returns the configured window.
    def window(
      options : Core::WindowOptions,
      html : String? = nil,
      parent_label : String? = nil,
      x : Int32? = nil,
      y : Int32? = nil,
      &
    )
      window = window(options, html: html, parent_label: parent_label, x: x, y: y)
      yield window
      window
    end

    # Configure a callback fired when the primary window is created and IPC is ready.
    def on_ready(&block : Core::Window -> Nil) : self
      @runtime.on_ready = block
      self
    end

    # Register a callback to run during `#shutdown` (after the main window
    # closes, before the process exits). Hooks run in reverse registration
    # order, after plugin cleanup. Use this for resources your app owns:
    # database connections, sockets, persisted UI state.
    #
    # ```
    # app.on_shutdown { db.close }
    # app.on_shutdown { server.stop }
    # ```
    def on_shutdown(&block : -> Nil) : self
      @runtime.lifecycle.on_shutdown(&block)
      self
    end

    # Register an app-wide vetoable shutdown interceptor that runs *before*
    # `App#quit` terminates the run loop, so the app can prompt "save
    # changes?" and actually wait for the answer.
    #
    # The block may return either:
    #
    # * `Bool` synchronously — `true` to allow the quit, `false` to veto
    #   and keep the app running.
    # * `CrystKit::Future(Bool)` — resolved later (e.g. from a native
    #   dialog callback on the UI fiber). `App#quit` awaits it up to
    #   `App#before_quit_timeout=`; an unresolved future cancels the quit.
    #
    # This complements per-window `Window#on_close` (which is synchronous).
    # The OS close button still routes through `Window#on_close`; use
    # `on_before_quit` for programmatic quit (`app.quit`, a "Quit" menu
    # item, etc.).
    #
    # Only one interceptor is supported; registering again replaces it.
    #
    # ```
    # app.on_before_quit do
    #   future = CrystKit::Future(Bool).new
    #   prompt_save_changes(on_decision: ->(saving) { future.resolve(saving) })
    #   future
    # end
    # ```
    def on_before_quit(&block : -> Bool | CrystKit::Future(Bool)) : self
      @runtime.before_quit_handler = block
      self
    end

    # The maximum time `App#quit` waits for an async `on_before_quit`
    # handler to resolve before treating it as a veto. `nil` waits
    # indefinitely. Defaults to `nil`.
    def before_quit_timeout=(timeout : Time::Span?) : Time::Span?
      @runtime.before_quit_timeout = timeout
    end

    # The configured `on_before_quit` timeout, or `nil` to wait forever.
    def before_quit_timeout : Time::Span?
      @runtime.before_quit_timeout
    end

    # Run the application: starts the primary window's event loop and
    # blocks until it is closed. `#shutdown` runs in an ensure block,
    # so cleanup happens exactly once. Raises `Core::Error`
    # when called before any window has been created.
    def run : Nil
      window = window_registry.primary
      raise Core::Error.new("App#run called without a window. Call #window first.") unless window
      @runtime.activations.on_event do |activation|
        if activation.type == Features::ActivationTypes::Files
          associations = file_associations
          activation.values.each { |path| associations.handle_open(path) }
        end
      end
      @runtime.lifecycle.running = true
      # macOS AppKit menu objects are installed from the first active native
      # run-loop dispatch, after NSApplication/WebView initialization settles.
      window.dispatch { @runtime.apply_menu_bar_bindings(window) }
      @runtime.on_ready.try(&.call(window))
      window.run
    ensure
      @runtime.lifecycle.running = false
      begin
        shutdown
      rescue ex
        Log.error(exception: ex) { "Shutdown error" }
      end
    end

    # Build, configure, and run in one block. The block receives the `App`
    # instance — call `plugin`, `window`, etc. via that receiver.
    #
    # ```
    # CrystKit::App.run do |app|
    #   app.plugin CrystKit::Plugins::FS.new
    #
    #   app.command "greet", String do |name|
    #     "Hello, #{name}"
    #   end
    #
    #   app.window title: "My App", html: "<h1>Hi</h1>"
    # end
    # ```
    def self.run(config : AppConfig = AppConfig.new, &block : App ->) : Nil
      app = new(config)
      block.call(app)
      app.run
    end

    # Request application exit. When running, runs any registered
    # `on_before_quit` interceptor first: a synchronous `false` (or an
    # async future that resolves `false` or fails to resolve within
    # `#before_quit_timeout`) cancels the quit and keeps the app running.
    # Otherwise terminates the primary window. When not running, performs
    # cleanup immediately via `#shutdown`.
    def quit : Nil
      if running?
        return unless allow_quit?
        if window = primary_window
          window.terminate
        else
          shutdown
        end
      else
        shutdown
      end
    end

    # Alias for `#quit`.
    def terminate : Nil
      quit
    end

    # Shut down: stop shortcut input, execute lifecycle hooks, clean up plugins
    # and native features, then destroy every window. Exceptions during
    # teardown are logged and do not prevent the remaining cleanup steps.
    #
    # Explicit invocation is only needed when the app is torn down
    # without entering the run loop (e.g. in tests or embedding hosts).
    def shutdown : Nil
      @asset_fetcher.clear
      @runtime.shutdown
    end

    # Attach the native desktop runtime (GUI thread + dispatcher) before any
    # native window operation. Runs once, before window creation, so a
    # `visible: false` window can be hidden without "runtime not attached".
    # The dispatcher routes through `MainThread`, which queues work onto the
    # primary window's webview loop once registered.
    private def attach_native_runtime : Nil
      return if ::NativeDesktop::Runtime.attached?
      ::NativeDesktop::Runtime.attach_to_current_thread(
        background: ->(block : Proc(Nil)) do
          ::CrystKit::Core::Fibers.spawn(name: "native-desktop") { block.call }
          nil
        end
      ) do |block|
        ::CrystKit::Core::MainThread.dispatch { block.call }
      end
    end

    # Wire IPC, plugins, protocols, and CSP into a newly created window.
    # :nodoc:
    private def wire_window(wv : T, window : Core::Window) forall T
      if security.capabilities.window_restrictions? && window.label.nil?
        raise Core::SecurityError.new(
          "Window '#{window.id}' must have a label because capabilities manifest defines per-window grants",
          code: "WINDOW_LABEL_REQUIRED",
        )
      end

      label = window.label || window.id
      window_security = Security::Context.new(
        capabilities: security.capabilities,
        scopes: security.scopes,
        resource_scopes: security.resource_scopes,
        window_id: label,
      )

      # Register the primary window's dispatch closure with MainThread
      # so framework features can route native calls onto the webview's
      # thread. Only the first (primary) window is registered.
      if window_registry.primary.same?(window)
        ::CrystKit::Core::MainThread.register(Fiber.current, window)
        @runtime.taskbar_progress.try(&.install(window.window, @config.identifier))
      end

      wv.setup_ipc_client(
        router,
        IPC::Context.new(
          app: self,
          security: window_security,
          window: window,
          plugins: plugins,
        ),
      )
      register_build_protocols(wv)
      inject_csp(wv)
      notify_plugins_window_created(window)
    end

    # :nodoc:
    private def inject_csp(wv : T) : Nil forall T
      csp = @config.csp
      return if !csp || csp.empty?
      wv.init(csp_js(csp))
    end

    # :nodoc:
    private def csp_js(csp : String) : String
      <<-JS
var meta = document.createElement('meta');
meta.httpEquiv = 'Content-Security-Policy';
meta.content = #{csp.to_json};
document.head.appendChild(meta);
JS
    end

    # Auto-register custom protocols from the build config before navigation.
    # :nodoc:
    private def register_build_protocols(wv : T) : Nil forall T
      @config.protocols.each do |protocol_config|
        opts = Features::ProtocolOptions.new(
          scheme: protocol_config.scheme,
          serve_assets: protocol_config.serve_assets?,
          asset_root: protocol_config.asset_root,
        )
        proto = Features::CustomProtocol.new(opts, runtime.platform.custom_protocol)
        proto.register(wv)
      rescue ex
        Log.warn { "Failed to register protocol '#{protocol_config.scheme}://': #{ex.message}" }
      end
    end

    @asset_protocol : Features::CustomProtocol?

    # Returns `true` when the window's navigation target requires the
    # built-in `crystkit://` asset protocol to be registered:
    #
    # * No *url* and no *html* — the window falls back to
    #   `default_nav_url`, which resolves to `crystkit://localhost/`
    #   when assets are available.
    # * *url* explicitly uses the `crystkit://` scheme (or the Windows
    #   `https://crystkit.localhost/` form) — the user wants content
    #   served from the asset protocol.
    #
    # Returns `false` when *html* is given (inline content, no URL
    # navigation) or when *url* targets an external scheme (http, https,
    # file, data, …).
    private def needs_asset_protocol?(url : String?, html : String?) : Bool
      return false unless html.nil?
      return true if url.nil?
      uses_asset_scheme?(url)
    end

    # Returns `true` when *url* targets the built-in asset protocol,
    # checked against `App.asset_origin` so the scheme form is correct
    # for the current platform.
    private def uses_asset_scheme?(url : String) : Bool
      origin = self.class.asset_origin
      url.starts_with?(origin) || url.starts_with?(origin.rchop('/'))
    end

    # Idempotent. Loads @asset_source from AssetLoader if not already
    # loaded and a vpak/frontend dir is available. Does NOT register the
    # crystkit:// scheme. Safe to call from any control constructor.
    private def load_asset_source! : Nil
      return if @asset_source
      @asset_source = Features::AssetLoader.load(
        frontend_dir: resolve_frontend_dir,
        package_name: @config.name,
      )
    end

    # Registers the crystkit:// scheme using the already-loaded asset
    # source. Still gated by asset_protocol_enabled?.
    private def setup_asset_protocol : Nil
      return unless @config.asset_protocol_enabled?
      load_asset_source!
      return unless @asset_source
      return if @asset_protocol
      opts = Features::ProtocolOptions.new(ASSET_SCHEME)
      opts.asset_source = @asset_source
      proto = Features::CustomProtocol.new(opts, runtime.platform.custom_protocol)
      proto.setup
      @asset_protocol = proto
      Log.info { "Built-in asset protocol registered: #{ASSET_SCHEME}://" }
    end

    private def resolve_frontend_dir : String?
      @config.frontend_dist || ENV["CRYSTKIT_FRONTEND_DIR"]?
    end

    # When `crystkit dev` spawns the app, it sets `CRYSTKIT_DEV_URL` so the
    # app navigates to the Vite/dev server instead of the asset protocol.
    # `nil` in production (uses the asset protocol).
    def dev_url : String?
      ENV["CRYSTKIT_DEV_URL"]?
    end

    # Returns the URL a window should navigate to when no explicit url/html
    # is given. Dev server URL takes precedence; otherwise the asset protocol
    # origin when assets are available.
    private def default_nav_url : String?
      return dev_url if dev_url
      @asset_source ? self.class.asset_origin : nil
    end

    # Notify all registered plugins that a new window has been created.
    # Errors in individual plugins are logged but do not block window creation.
    # :nodoc:
    private def notify_plugins_window_created(window : Core::Window) : Nil
      plugins.each do |plugin|
        plugin.on_window_created(window)
      rescue ex
        Log.error { "Plugin '#{plugin.identifier}' on_window_created failed: #{ex.message}" }
      end
    end

    # :nodoc:
    # Returns `true` when no `on_before_quit` interceptor is registered,
    # or when the registered interceptor allows the quit. A `nil` result
    # from a resolved future is treated as a veto, since "save changes?"
    # defaulting to "do not quit" is safer than data loss. An unresolved
    # future (timeout elapsed) also vetoes.
    private def allow_quit? : Bool
      handler = @runtime.before_quit_handler
      return true unless handler

      result = handler.call
      case result
      when Bool
        result
      when CrystKit::Future(Bool)
        case resolved = result.get?(@runtime.before_quit_timeout)
        when Bool
          resolved
        else
          false
        end
      else
        true
      end
    end

    # Push a backend event down to frontend listeners.
    # If a target window is specified, only that window receives the event.
    # :nodoc:
    private def bridge_to_frontend(event : String, payload : JSON::Any, target : Core::Window? = nil) : Nil
      if dispatcher = @runtime.frontend_event_dispatcher
        dispatcher.call(event, payload, target)
        return
      end
      return unless running?
      js = "if (window.__CRYSTKIT_IPC__) { window.__CRYSTKIT_IPC__._dispatchEvent(#{event.to_json}, #{payload.to_json}); }"
      if target
        target.dispatch_eval(js)
      else
        window_registry.all.each(&.dispatch_eval(js))
      end
    rescue ex
      Log.error { "Failed to bridge event '#{event}' to frontend: #{ex.message}" }
    end

    # Coerce an arbitrary Crystal value into `JSON::Any` for IPC transport.
    #
    # Notable mappings:
    #   - `Bytes`  -> base64 string
    #   - `Enum`   -> string name
    #   - `UInt64` -> narrowed to `Int64` when it fits (JS numbers are
    #     IEEE-754 doubles and cannot losslessly represent the full
    #     `UInt64` range). Values exceeding `Int64::MAX` degrade to
    #     `Float64` — the same precision JS `Number` would have for
    #     such magnitudes, and the only numeric `JSON::Any` can hold
    #     beyond the `Int64` range.
    #
    # The framework auto-applies this to every command's return value.
    # Raises `Core::IPCError` when *value* cannot be represented as JSON.
    def coerce_to_json(value) : JSON::Any
      IPC::Codec.to_json_any(value)
    rescue ex : Core::IPCError
      raise ex
    rescue ex
      Log.warn(exception: ex) { "Failed to coerce #{value.class} to JSON::Any" }
      JSON::Any.new(nil)
    end
  end
end
