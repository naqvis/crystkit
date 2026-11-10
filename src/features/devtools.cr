require "json"
require "log"
require "../core/errors"
require "../platform/backends/window_integration_backend"

module CrystKit
  module Features
    # Docking mode for the developer tools panel.
    enum DevToolsDockMode
      # Undocked floating window
      Undocked
      # Docked to the bottom of the webview
      Bottom
      # Docked to the right of the webview
      Right
      # Docked to the left of the webview
      Left
    end

    # A forwarded console message from the webview JavaScript context.
    struct ConsoleMessage
      # Console level as reported by the webview: `"log"`, `"info"`,
      # `"warn"`, `"error"`, `"debug"`, etc.
      getter level : String
      # The rendered text of the console call.
      getter text : String
      # URL of the script that emitted the message, or `""` when unavailable.
      getter source : String
      # 1-based line number in *source*, or `0` when unavailable.
      getter line : Int32

      # Creates a console message value from webview-reported data.
      def initialize(@level : String, @text : String, @source = "", @line = 0)
      end
    end

    # A JavaScript error reported from the webview context.
    struct JSError
      # The error message text.
      getter message : String
      # URL of the script that raised the error, or `""` when unavailable.
      getter source : String
      # 1-based line number in *source*, or `0` when unavailable.
      getter line : Int32
      # 1-based column number in *source*, or `0` when unavailable.
      getter column : Int32
      # Stack trace string as formatted by the webview, or `nil` when absent.
      getter stack : String?

      # Creates a JavaScript error value from webview-reported data.
      def initialize(
        @message : String,
        @source = "",
        @line = 0,
        @column = 0,
        @stack = nil,
      )
      end
    end

    # Configuration for the DevTools feature.
    struct DevToolsConfig
      # Whether dev tools are enabled. Should only be true in debug builds.
      property? enabled : Bool
      # Default docking mode when opening dev tools.
      property dock_mode : DevToolsDockMode
      # Whether to forward console messages to the Crystal backend.
      property? forward_console : Bool
      # Whether to forward JavaScript errors to the Crystal backend.
      property? forward_js_errors : Bool
      # Remote debugging port (0 = disabled).
      property remote_debug_port : Int32

      # Creates a dev tools config with the given settings.
      #
      # Defaults to a disabled, bottom-docked configuration with no
      # forwarding and no remote debug port — appropriate for production.
      # Use `DevTools.default_config` to obtain a build-mode-aware
      # configuration instead.
      def initialize(
        @enabled = false,
        @dock_mode = DevToolsDockMode::Bottom,
        @forward_console = false,
        @forward_js_errors = false,
        @remote_debug_port = 0,
      )
      end
    end

    # Developer tools integration for the webview.
    #
    # Provides browser developer tools (inspector) support during development.
    # Dev tools are only available when the `enabled` flag is set in the config,
    # which should be tied to the application's debug/release build mode.
    #
    # Console messages and JavaScript errors can be forwarded to the Crystal
    # backend for logging and inspection.
    class DevTools
      # :nodoc:
      @config : DevToolsConfig
      # :nodoc:
      @open : Bool
      # :nodoc:
      @console_handlers : Array(Proc(ConsoleMessage, Nil))
      # :nodoc:
      @error_handlers : Array(Proc(JSError, Nil))
      # :nodoc:
      @open_handlers : Array(Proc(Nil))
      # :nodoc:
      @close_handlers : Array(Proc(Nil))

      # Creates a dev tools controller from *config* and an optional
      # *backend*.
      #
      # *backend* defaults to the platform's current native window
      # integration backend and is injectable primarily for tests.
      def initialize(
        @config = DevToolsConfig.new,
        @backend : Platform::WindowIntegrationBackend = Platform::CurrentWindowIntegrationBackend.new,
      )
        @open = false
        @console_handlers = [] of Proc(ConsoleMessage, Nil)
        @error_handlers = [] of Proc(JSError, Nil)
        @open_handlers = [] of Proc(Nil)
        @close_handlers = [] of Proc(Nil)
      end

      # Returns whether dev tools are currently open.
      def open? : Bool
        @open
      end

      # Returns whether dev tools are enabled in the current configuration.
      def enabled? : Bool
        @config.enabled?
      end

      # Returns the current configuration.
      def config : DevToolsConfig
        @config
      end

      # Open the developer tools panel.
      #
      # Does nothing if dev tools are disabled (production mode) or already open.
      # Raises `Core::Error` if the platform fails to open dev tools.
      def open(native_window : Pointer(Void) = Pointer(Void).null) : Nil
        unless @config.enabled?
          Log.debug { "DevTools: open() called but dev tools are disabled (production mode)" }
          return
        end

        return if @open

        Log.debug { "DevTools: opening (dock_mode=#{@config.dock_mode})" }
        ::CrystKit::Core::MainThread.dispatch_sync {
          @backend.open_devtools(native_window, @config.dock_mode.value)
        }
        @open = true
        @open_handlers.each(&.call)
      end

      # Close the developer tools panel.
      #
      # Does nothing if dev tools are not open.
      def close(native_window : Pointer(Void) = Pointer(Void).null) : Nil
        return unless @open

        Log.debug { "DevTools: closing" }
        ::CrystKit::Core::MainThread.dispatch_sync {
          @backend.close_devtools(native_window)
        }
        @open = false
        @close_handlers.each(&.call)
      end

      # Toggle the developer tools panel open/closed.
      def toggle(native_window : Pointer(Void) = Pointer(Void).null) : Nil
        if @open
          close(native_window)
        else
          open(native_window)
        end
      end

      # Change the docking mode of the developer tools.
      # If dev tools are currently open, re-opens them with the new mode.
      def set_dock_mode(mode : DevToolsDockMode, native_window : Pointer(Void) = Pointer(Void).null) : Nil
        @config.dock_mode = mode
        if @open
          close(native_window)
          open(native_window)
        end
      end

      # Register a handler that is called when a console message is forwarded.
      def on_console_message(&handler : ConsoleMessage ->)
        @console_handlers << handler
      end

      # Register a handler that is called when a JavaScript error is reported.
      def on_js_error(&handler : JSError ->)
        @error_handlers << handler
      end

      # Register a handler called when dev tools are opened.
      def on_open(&handler : ->)
        @open_handlers << handler
      end

      # Register a handler called when dev tools are closed.
      def on_close(&handler : ->)
        @close_handlers << handler
      end

      # Called internally to dispatch a forwarded console message to all handlers.
      # :nodoc:
      def handle_console_message(msg : ConsoleMessage) : Nil
        return unless @config.forward_console?
        Log.debug { "DevTools[console/#{msg.level}]: #{msg.text}" }
        @console_handlers.each do |handler|
          begin
            handler.call(msg)
          rescue ex
            Log.error { "DevTools: console handler raised: #{ex.message}" }
          end
        end
      end

      # Called internally to dispatch a JavaScript error to all handlers.
      # :nodoc:
      def handle_js_error(err : JSError) : Nil
        return unless @config.forward_js_errors?
        Log.warn { "DevTools[js_error]: #{err.message} at #{err.source}:#{err.line}" }
        @error_handlers.each do |handler|
          begin
            handler.call(err)
          rescue ex
            Log.error { "DevTools: error handler raised: #{ex.message}" }
          end
        end
      end

      # Returns the remote debugging port, or 0 if remote debugging is disabled.
      def remote_debug_port : Int32
        @config.remote_debug_port
      end

      # Returns true if remote debugging is configured.
      def remote_debugging? : Bool
        @config.remote_debug_port > 0
      end

      # Build mode detection: returns :debug or :release based on compile flags.
      def self.build_mode : Symbol
        {% if flag?(:release) %}
          :release
        {% else %}
          :debug
        {% end %}
      end

      # Create a DevToolsConfig appropriate for the current build mode.
      # In debug builds, dev tools are enabled by default.
      # In release builds, dev tools are disabled.
      def self.default_config : DevToolsConfig
        {% if flag?(:release) %}
          DevToolsConfig.new(enabled: false)
        {% else %}
          DevToolsConfig.new(
            enabled: true,
            forward_console: true,
            forward_js_errors: true,
          )
        {% end %}
      end
    end
  end
end
