require "json"
require "../core/errors"
require "../ipc/router"
require "../ipc/policy"
require "../security/context"

module CrystKit
  class App; end

  # The plugin subsystem: a typed extension mechanism exposing IPC commands
  # and events to plugins via a shared `Plugin::Context`.
  module Plugin
    # Forward declaration; the full `Plugin::Registry` is defined in registry.cr.
    class Registry; end

    # Static contract describing a plugin's identity, dependencies, and the IPC
    # surface it is permitted to expose.
    #
    # Returned by `Plugin::Base#metadata` and validated by
    # `Plugin::Registry` at registration time. The `id` *must* equal
    # `Plugin::Base#identifier`; the registry raises `Core::PluginError`
    # on mismatch. All collections default to empty, so a minimal plugin
    # can return `Metadata.new(identifier)`.
    struct Metadata
      # The unique plugin identifier this metadata describes.
      #
      # Must match `Plugin::Base#identifier` exactly.
      getter id : String

      # Identifiers of other plugins that must already be registered before
      # this one can be installed.
      getter dependencies : Array(String)

      # Security capabilities the plugin requires to function.
      #
      # Each entry must match ``\A[a-zA-Z0-9_:.\-]+\z``.
      getter capabilities : Array(String)

      # IPC command names the plugin promises to register.
      #
      # After `initialize_plugin` returns, the registry cross-checks the
      # commands actually registered against this list; any mismatch
      # raises `Core::PluginError` and rolls back the plugin. Command
      # names should be dot-namespaced, e.g. `fs.read_text`.
      getter commands : Array(String)

      # Event names the plugin is allowed to emit (backend → frontend).
      #
      # `Plugin::Context#emit` raises `Core::PluginError` for events not
      # listed here. These events are **not** automatically declared as
      # frontend-emittable — they originate from trusted backend code and
      # the frontend is not permitted to emit them.
      getter events : Array(String)

      # Event names the frontend is allowed to emit that this plugin will
      # listen to (frontend → backend).
      #
      # The registry declares these via `Router#declare_frontend_event`
      # during plugin registration so the router's security policy permits
      # the frontend to emit them. Without this declaration, frontend
      # `ipc.emit(name, ...)` for these events would be rejected with
      # `IPC_POLICY_MISSING`.
      #
      # Use this for events that originate from the JS side, e.g. a
      # stats-tracking wrapper that emits `__stats:call__` on every
      # `ipc.invoke`.
      getter frontend_events : Array(String)

      # Per-command security policies applied before frontend IPC reaches the
      # plugin's handlers.
      #
      # Each command referenced here must also appear in `commands`;
      # otherwise the registry raises `Core::PluginError`. Use
      # `IPC::PolicyCatalog` helpers (`require`, `path`, `resource`,
      # `public`) to build this catalog fluently.
      getter ipc : ::CrystKit::IPC::PolicyCatalog

      # Creates metadata for the plugin identified by *id*.
      #
      # All collections default to empty; *ipc*'s command keys must be a
      # subset of *commands*.
      def initialize(
        @id,
        @dependencies = [] of String,
        @capabilities = [] of String,
        @commands = [] of String,
        @events = [] of String,
        @frontend_events = [] of String,
        @ipc = ::CrystKit::IPC::PolicyCatalog.new,
      )
      end
    end

    # The application context shared with plugins.
    #
    # Exposes the parent `app`, the shared IPC `router`, the plugin's
    # security `context` (capabilities + scopes), a per-plugin `config`
    # slice, and helpers (`command`, `command_context`, `emit`,
    # `listen`) that register IPC handlers attributed to this plugin.
    #
    # Passed to plugins as the argument to `Plugin::Base#initialize_plugin`.
    class Context
      # The parent `CrystKit::App` driving this plugin.
      getter app : ::CrystKit::App

      # The shared IPC router commands and events are wired onto.
      #
      # Prefer the `command`, `emit`, and `listen` helpers on this
      # context over calling the router directly.
      getter router : ::CrystKit::IPC::Router

      # The security context scoped to this plugin.
      getter security : ::CrystKit::Security::Context

      # This plugin's configuration slice decoded from the app's plugin config.
      #
      # Defaults to an empty JSON object when no per-plugin config was provided.
      getter config : JSON::Any

      # Creates a context bound to *app* and the owning *registry*.
      #
      # *plugin_id* attributes every command/event registered through
      # this context back to the plugin. Plugin authors never construct
      # a `Context` directly.
      def initialize(
        @app,
        @router,
        @security,
        @registry : Registry,
        @plugin_id : String,
        @config = JSON::Any.new(Hash(String, JSON::Any).new),
      )
      end

      # Shortcut for `security.capabilities`.
      def capabilities : ::CrystKit::Security::CapabilitySystem
        @security.capabilities
      end

      # Shortcut for `security.scopes`.
      def scopes : ::CrystKit::Security::ScopeManager
        @security.scopes
      end

      # Registers an IPC command with no typed parameters.
      #
      # The block takes no arguments and its return value is auto-coerced
      # to `JSON::Any` before being sent back to the caller.
      #
      # ```
      # context.command("clipboard.read_text") { clipboard.read_text }
      # ```
      def command(name : String, &block : -> R) forall R
        register_command_handler(name, ->(_params : ::JSON::Any) {
          begin
            coerce_to_json(block.call)
          rescue ex : ::CrystKit::Core::Error
            raise ex
          rescue ex
            raise ::CrystKit::Core::IPCError.new("Command failed: #{ex.message}", code: "COMMAND_EXECUTION_ERROR")
          end
        })
      end

      # Registers a command whose single argument is decoded from the complete payload.
      #
      # *input_type* is a `JSON::Serializable` type; the entire IPC payload
      # is decoded into it and yielded to the block. The return value is
      # auto-coerced to `JSON::Any`.
      #
      # ```
      # context.command("fs.write_text", WriteTextRequest) { |req| fs.write_text(Path[req.path], req.content); "ok" }
      # ```
      def command(name : String, input_type : T.class, &block : T -> R) forall T, R
        register_command_handler(name, ->(params : ::JSON::Any) {
          begin
            coerce_to_json(block.call(::CrystKit::IPC::Router.decode(params, input_type)))
          rescue ex : ::CrystKit::Core::Error
            raise ex
          rescue ex
            raise ::CrystKit::Core::IPCError.new("Command failed: #{ex.message}", code: "COMMAND_EXECUTION_ERROR")
          end
        })
      end

      ::CrystKit.define_sync_typed_commands(2..6, "command", "register_command_handler")

      # Registers a command that receives the live `IPC::Context` for the
      # invocation in addition to the decoded payload.
      #
      # The block is handed the per-call `IPC::Context` (carrying window,
      # security, frontend flag, etc.), letting the handler tailor
      # behavior to the caller. The return value is auto-coerced to
      # `JSON::Any`.
      #
      # ```
      # context.command_context("window.close") { |ctx, params| ctx.window.try(&.close); "ok" }
      # ```
      def command_context(name : String, &block : ::CrystKit::IPC::Context, ::JSON::Any -> R) forall R
        @registry.register_contextual_command(@plugin_id, name, ->(invocation : ::CrystKit::IPC::Context, params : ::JSON::Any) {
          @app.coerce_to_json(block.call(invocation, params))
        })
      end

      # Registers an **asynchronous** IPC command with no typed parameters.
      #
      # The handler runs on its own fiber with a real `select` timeout,
      # so the UI thread stays responsive during blocking I/O.
      def async(name : String, timeout : Time::Span? = nil, &block : -> R) forall R
        register_async_command_handler(name, ->(_params : ::JSON::Any, _token : ::CrystKit::Core::CancellationToken) {
          begin
            coerce_to_json(block.call)
          rescue ex : ::CrystKit::Core::Error
            raise ex
          rescue ex
            raise ::CrystKit::Core::IPCError.new("Async command failed: #{ex.message}", code: "COMMAND_EXECUTION_ERROR")
          end
        }, timeout)
      end

      # Registers an **asynchronous** command whose single argument is
      # decoded from the complete payload.
      def async(name : String, input_type : T.class, timeout : Time::Span? = nil,
                &block : T, ::CrystKit::Core::CancellationToken -> R) forall T, R
        register_async_command_handler(name, ->(params : ::JSON::Any, token : ::CrystKit::Core::CancellationToken) {
          begin
            coerce_to_json(block.call(::CrystKit::IPC::Router.decode(params, input_type), token))
          rescue ex : ::CrystKit::Core::Error
            raise ex
          rescue ex
            raise ::CrystKit::Core::IPCError.new("Async command failed: #{ex.message}", code: "COMMAND_EXECUTION_ERROR")
          end
        }, timeout)
      end

      # Registers an **asynchronous** command with one argument (no
      # cancellation token). See `#async(name, input_type, timeout, &block)`.
      def async(name : String, input_type : T.class, timeout : Time::Span? = nil,
                &block : T -> R) forall T, R
        register_async_command_handler(name, ->(params : ::JSON::Any, _token : ::CrystKit::Core::CancellationToken) {
          begin
            coerce_to_json(block.call(::CrystKit::IPC::Router.decode(params, input_type)))
          rescue ex : ::CrystKit::Core::Error
            raise ex
          rescue ex
            raise ::CrystKit::Core::IPCError.new("Async command failed: #{ex.message}", code: "COMMAND_EXECUTION_ERROR")
          end
        }, timeout)
      end

      # :nodoc: Wraps a raw async handler for the router's async transport.
      def register_async_command_handler(cmd : String, handler : Proc(::JSON::Any, Core::CancellationToken, JSON::Any),
                                         timeout : Time::Span? = nil)
        @registry.register_async_command(@plugin_id, cmd, ->(context : ::CrystKit::IPC::Context, params : ::JSON::Any, token : ::CrystKit::Core::CancellationToken) {
          handler.call(params, token)
        }, timeout: timeout)
      end

      ::CrystKit.define_async_typed_commands(2..6, "async", "register_async_command_handler")

      def coerce_to_json(value) : JSON::Any
        @app.coerce_to_json(value)
      end

      # :nodoc: Wraps a raw handler for the router's JSON transport.
      def register_command_handler(cmd : String, handler : Proc(::JSON::Any, JSON::Any))
        @registry.register_command(@plugin_id, cmd, ->(params : ::JSON::Any) {
          handler.call(params)
        })
      end

      # Emits *event* with *payload* from a plugin.
      #
      # The event must be declared in `Metadata#events` or the registry
      # raises `Core::PluginError`. Delivery reaches both backend
      # subscribers and frontend listeners.
      #
      # ```
      # context.emit("updater.available", context.app.coerce_to_json({"version" => "1.2.0"}))
      # ```
      def emit(event : String, payload : JSON::Any) : Nil
        @registry.emit_event(@plugin_id, event, payload)
        @app.bridge_event_to_frontend(event, payload)
      end

      # Subscribes *handler* to *event* from a plugin.
      #
      # The handler is invoked for every emission of *event* (from any
      # source). The returned `UInt64` subscription id is automatically
      # revoked when the plugin is cleaned up.
      #
      # ```
      # context.listen("shortcuts.triggered") { |payload| handle(payload["accelerator"].as_s) }
      # ```
      def listen(event : String, &handler : JSON::Any -> Nil) : UInt64
        @registry.subscribe_event(@plugin_id, event, handler)
      end
    end

    # Abstract base class for all plugins.
    #
    # Subclasses implement `identifier` and `initialize_plugin`, and
    # optionally override `metadata`, `cleanup_plugin`,
    # `on_window_created`, and `extend_window_options`. Register via
    # `CrystKit::App#plugin`.
    abstract class Base
      # Returns the unique identifier for this plugin (alphanumeric, 1-64 chars).
      #
      # Must match ``\A[a-zA-Z0-9_-]{1,64}\z`` and be unique across all
      # registered plugins. It must equal `Metadata#id`.
      abstract def identifier : String

      # Initializes the plugin. Called once during registration. Register
      # IPC commands and event listeners here via `context.command`,
      # `context.emit`, and `context.listen`.
      #
      # Registered commands must exactly match `metadata.commands` or
      # registration is rolled back with `Core::PluginError`.
      abstract def initialize_plugin(context : Context) : Nil

      # Cleans up plugin resources. Called on app shutdown or unregister.
      #
      # Override to close handles, stop timers, detach observers, etc.
      # The default is a no-op. Errors raised here are logged and
      # swallowed so one failing cleanup does not block the rest.
      def cleanup_plugin : Nil
      end

      # Returns the metadata contract for this plugin.
      #
      # The default sets only `identifier` with empty collections; override
      # to declare dependencies, capabilities, commands, events, and IPC
      # policy. Must be deterministic and not depend on runtime state.
      def metadata : Metadata
        Metadata.new(identifier)
      end

      # Called when a new window is created, before any content is loaded.
      # Override to configure the window (e.g. install platform delegates).
      # Default is a no-op.
      def on_window_created(window : ::CrystKit::Core::Window) : Nil
      end

      # Mutates the *options* hash used to construct a window, letting
      # plugins add or override window options before the window is
      # created. Default is a no-op.
      def extend_window_options(options : Hash(String, JSON::Any))
      end
    end
  end

  module Core
    class Window; end
  end
end
