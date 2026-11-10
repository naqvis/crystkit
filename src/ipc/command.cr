require "json"
require "./policy"

module CrystKit
  # Forward declaration of the application root, fully defined in
  # `src/app/app.cr`.
  class App; end

  module Core
    # Forward declaration of a CrystKit window handle, fully defined in
    # `src/core/window.cr`.
    class Window; end
  end

  module Plugin
    # Forward declaration of the plugin registry, fully defined in
    # `src/plugins/registry.cr`.
    class Registry; end
  end

  module Security
    # Forward declaration of the security context, fully defined in
    # `src/security/context.cr`.
    class Context; end
  end

  module IPC
    # Type of a command handler that only consumes the JSON payload.
    alias CommandHandler = Proc(JSON::Any, JSON::Any)

    # Type of a command handler that receives the `IPC::Context` in
    # addition to the JSON payload. Use this when a handler needs to
    # inspect the caller, the active security context, the originating
    # window, or the plugin registry.
    alias ContextualCommandHandler = Proc(Context, JSON::Any, JSON::Any)

    # Type of an async command handler.  Receives the `IPC::Context`, the
    # JSON payload, and a `CancellationToken` that the handler can poll
    # or check to bail out early when the command's timeout fires.
    # Returns `JSON::Any` like the sync variant — the framework handles
    # fiber dispatch and deferred response delivery.
    alias AsyncContextualCommandHandler = Proc(Context, JSON::Any, Core::CancellationToken, JSON::Any)

    # Metadata carried alongside every IPC command invocation, telling the
    # handler *who* is asking and *what they are allowed to do*.
    #
    # Handlers should treat the context as read-only metadata. Fields may
    # be `nil` when the corresponding service is not available to the
    # caller.
    struct Context
      # The running CrystKit application, if this invocation is happening
      # inside a live app. `nil` outside a live app.
      getter app : ::CrystKit::App?

      # The security context used to authorize this invocation. For
      # frontend calls this is the per-window scoped context; for backend
      # calls usually `nil`. Policy enforcement raises `SecurityError` when
      # a command requires capabilities or resource scopes but this is
      # `nil`.
      getter security : ::CrystKit::Security::Context?

      # The window the call originated from or is targeted at. Frontend
      # invocations carry the webview's `Core::Window`; backend invocations
      # generally leave this `nil`.
      getter window : ::CrystKit::Core::Window?

      # The plugin registry, or `nil` outside an application that owns one.
      getter plugins : ::CrystKit::Plugin::Registry?

      # Identifier of the plugin that registered the command being invoked,
      # when applicable.
      getter plugin_id : String?

      # `true` when the call crossed the JS↔Crystal boundary. The router
      # runs `CommandPolicy` checks only on frontend calls; backend calls
      # are trusted.
      getter? frontend : Bool

      # Origin string of the calling page, when available from the webview.
      getter origin : String?

      # Creates a context with any subset of the invocation metadata.
      #
      # ```
      # # A backend context with no privileges attached.
      # ctx = IPC::Context.new
      #
      # # A frontend context bound to a window's security scope.
      # ctx = IPC::Context.new(
      #   app: app, security: window_security,
      #   window: window, frontend: true,
      # )
      # ```
      def initialize(
        @app = nil,
        @security = nil,
        @window = nil,
        @plugins = nil,
        @plugin_id = nil,
        @frontend = false,
        @origin = nil,
      )
      end

      # Returns a stable identifier for the window authorizing this call:
      # the window's `label` if set, otherwise its `id`. `nil` when no
      # window is attached.
      def window_authority_id : String?
        @window.try { |w| w.label || w.id }
      end
    end
  end

  macro define_sync_typed_commands(range, method_name, register_method)
    {% raise "range should be RangeLiteral" unless range.is_a?(RangeLiteral) %}
    # Register a **synchronous** command with multiple typed positional
    # arguments. Each *typeN* declares the type of the Nth positional
    # argument. See `#command(name, &block)` for when to use `#command`
    # vs `#async`.
    #
    # ```
    # app.command "fs.write", String, String do |path, contents|
    #   File.write(path, contents)
    # end
    # ```
    {% for n in range %}
      {% targs = (1..n).map { |i| "T#{i}" }.join(", ") %}
      {% types = (1..n).map { |i| "type#{i} : T#{i}.class" }.join(", ") %}
      {% block_args = (1..n).map { |i| "T#{i}" }.join(", ") %}
      def {{method_name.id}}(name : String, {{types.id}}, &block : {{block_args.id}} -> R) forall {{targs.id}}, R
        {{register_method.id}}(name, ->(params : JSON::Any) {
          begin
            values = IPC::Router.arguments(params, {{n}})
            coerce_to_json(block.call(
              {% for i in 1..n %}
                IPC::Router.decode(values[{{i - 1}}], type{{i}}),
              {% end %}
            ))
          rescue ex : Core::Error
            raise ex
          rescue ex
            raise Core::IPCError.new("Command failed: #{ex.message}", code: "COMMAND_EXECUTION_ERROR")
          end
        })
      end
    {% end %}
  end

  macro define_async_typed_commands(range, method_name, register_method)
    {% raise "range should be RangeLiteral" unless range.is_a?(RangeLiteral) %}
    # Register an **asynchronous** command with multiple typed positional
    # arguments. Each *typeN* declares the type of the Nth positional
    # argument. The handler receives the decoded arguments followed by a
    # `CancellationToken` as the last parameter. See `#async(name, timeout,
    # &block)` for the sync-vs-async guidance. *timeout* overrides the
    # router's default `command_timeout` for this command only.
    #
    # ```
    # app.async "fs.copy", String, String, timeout: 10.seconds do |src, dst, cancel|
    #   FileUtils.cp(src, dst)
    #   true
    # end
    # ```
    {% for n in range %}
      {% targs = (1..n).map { |i| "T#{i}" }.join(", ") %}
      {% types = (1..n).map { |i| "type#{i} : T#{i}.class" }.join(", ") %}
      {% block_args = (1..n).map { |i| "T#{i}" }.join(", ") + ", Core::CancellationToken" %}
      def {{method_name.id}}(name : String, {{types.id}}, timeout : Time::Span? = nil,
                &block : {{block_args.id}} -> R) forall {{targs.id}}, R
        {{register_method.id}}(name, ->(params : JSON::Any, token : Core::CancellationToken) {
          begin
            values = IPC::Router.arguments(params, {{n}})
            coerce_to_json(block.call(
              {% for i in 1..n %}
                IPC::Router.decode(values[{{i - 1}}], type{{i}}),
              {% end %}
              token,
            ))
          rescue ex : Core::Error
            raise ex
          rescue ex
            raise Core::IPCError.new("Async command failed: #{ex.message}", code: "COMMAND_EXECUTION_ERROR")
          end
        }, timeout: timeout)
      end
    {% end %}
  end
end
