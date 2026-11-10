require "uri"
require "log"
require "native_desktop"
require "../core/errors"
require "../ipc/router"

module CrystKit
  module Features
    # :nodoc:
    abstract class URLSchemeProvider
      abstract def register_scheme(scheme : String, app_name : String, app_exec : String) : Nil
      abstract def unregister_scheme(scheme : String) : Nil
    end

    # :nodoc:
    class NativeURLSchemeProvider < URLSchemeProvider
      def register_scheme(scheme : String, app_name : String, app_exec : String) : Nil
        registration = ::NativeDesktop::URLSchemeRegistration.new(scheme, app_name, Path[app_exec])
        ::NativeDesktop.url_schemes.register(registration)
      end

      def unregister_scheme(scheme : String) : Nil
        ::NativeDesktop.url_schemes.unregister(scheme)
      end
    end

    # Represents a parsed deep link URL with its components.
    #
    # `DeepLinkURL` is the value type delivered to `on_open` handlers and
    # emitted on the IPC event bus when the OS activates a registered
    # scheme. It is `JSON::Serializable` so it can be serialised for IPC
    # payloads and for diagnostic logging.
    struct DeepLinkURL
      include JSON::Serializable

      # The URL scheme (e.g., `"myapp"`), without the trailing `://`.
      getter scheme : String
      # The URL host component, or `""` when absent.
      getter host : String
      # The URL path component, or `""` when absent.
      getter path : String
      # Decoded query parameters keyed by name. Parameters without a
      # value are stored with an empty-string value.
      getter query_params : Hash(String, String)
      # The original, unparsed URL string as received from the OS.
      getter raw_url : String

      # Creates a parsed deep link value from its components.
      def initialize(@scheme : String, @host : String, @path : String,
                     @query_params : Hash(String, String), @raw_url : String)
      end
    end

    # Deep linking support for custom URL scheme registration and handling.
    #
    # Allows applications to register custom URL schemes (e.g., "myapp://")
    # so the OS can launch or activate the application when such URLs are opened.
    #
    # Platform-specific registration:
    #   - Linux:   XDG .desktop file + xdg-mime
    #   - Windows: HKCU registry keys under Software\Classes\<scheme>
    #   - macOS:   Minimal .app bundle with Info.plist + lsregister
    #
    # Supports:
    # - Launching the application when a deep link is activated (14.2)
    # - Bringing an existing instance to the foreground (14.3)
    # - Emitting an event with the URL on activation (14.4)
    # - Parsing URL parameters from deep links (14.5)
    # - Handling deep links during application startup (14.8)
    # - Handling deep links while the application is running (14.9)
    class DeepLink
      # Maximum length for a URL scheme name (alphanumeric, 1-64 chars).
      SCHEME_MAX_LENGTH = 64

      # Regex for valid scheme names: alphanumeric only, 1-64 characters.
      SCHEME_PATTERN = /\A[a-zA-Z0-9]{1,64}\z/

      # Event name emitted on the IPC event bus when a deep link is activated.
      DEEP_LINK_EVENT = "deep-link"

      @schemes : Hash(String, Bool)
      @open_handlers : Array(Proc(DeepLinkURL, Nil))

      # Pending URLs received before the application was fully initialised.
      # These are queued during startup and flushed once `flush_startup_urls` is called.
      @startup_queue : Array(String)

      # Whether the application has finished startup and is ready to handle URLs.
      @started : Bool

      # Optional IPC event bus for emitting deep-link events.
      @router : IPC::Router?

      # Optional callback invoked to bring the application window to the foreground
      # when a deep link is activated while the app is already running.
      @foreground_handler : Proc(Nil)?

      # Human-readable application name used in platform registrations.
      getter app_name : String

      # Absolute path (or command) to the application executable.
      # Used by platform backends to build the OS handler command.
      getter app_exec : String

      # Create a new DeepLink manager.
      #
      # - *app_name*: Human-readable name shown in OS handler descriptions.
      # - *app_exec*: Path to the application executable (used by platform backends).
      #   Defaults to the current process executable path.
      def initialize(
        @app_name = "CrystKit Application",
        app_exec : String? = nil,
        @provider : URLSchemeProvider = NativeURLSchemeProvider.new,
      )
        resolved_exec = app_exec || Process.executable_path
        unless resolved_exec
          raise Core::Error.new(
            "Unable to determine application executable path for deep link registration",
            code: "EXECUTABLE_PATH_UNKNOWN"
          )
        end
        @app_exec = resolved_exec

        @schemes = Hash(String, Bool).new
        @open_handlers = Array(Proc(DeepLinkURL, Nil)).new
        @startup_queue = Array(String).new
        @started = false
        @router = nil
        @foreground_handler = nil
      end

      # Register a custom URL scheme with the operating system.
      #
      # The scheme must be alphanumeric and between 1 and 64 characters long.
      # Multiple schemes can be registered per application.
      #
      # Raises `Core::ValidationError` if the scheme format is invalid.
      # Raises `Core::Error` if the scheme is already registered or OS registration fails.
      def register_scheme(scheme : String) : Nil
        validate_scheme!(scheme)

        normalized = scheme.downcase

        if @schemes.has_key?(normalized)
          raise Core::Error.new(
            "URL scheme '#{scheme}' is already registered",
            code: "SCHEME_ALREADY_REGISTERED"
          )
        end

        begin
          @provider.register_scheme(normalized, @app_name, @app_exec)
        rescue ex
          raise Core::Error.new(
            "Failed to register URL scheme '#{scheme}': #{ex.message}",
            code: "SCHEME_REGISTER_FAILED"
          )
        end

        @schemes[normalized] = true
        Log.debug { "DeepLink: registered scheme '#{normalized}://'" }
      end

      # Unregister a previously registered URL scheme.
      #
      # No-op if the scheme was not registered.
      def unregister_scheme(scheme : String) : Nil
        normalized = scheme.downcase
        return unless @schemes.has_key?(normalized)

        begin
          @provider.unregister_scheme(normalized)
        rescue ex
          Log.warn { "DeepLink: failed to unregister scheme '#{normalized}': #{ex.message}" }
        end

        @schemes.delete(normalized)
        Log.debug { "DeepLink: unregistered scheme '#{normalized}://'" }
      end

      # Unregister all registered URL schemes.
      def unregister_all : Nil
        @schemes.keys.each { |scheme| unregister_scheme(scheme) }
      end

      # Returns all currently registered URL schemes.
      def registered_schemes : Array(String)
        @schemes.keys
      end

      # Returns true if the given scheme is registered.
      def registered?(scheme : String) : Bool
        @schemes.has_key?(scheme.downcase)
      end

      # Register a handler to be called when a deep link URL is opened.
      #
      # Multiple handlers can be registered; all will be called in order.
      def on_open(&handler : DeepLinkURL ->) : Nil
        @open_handlers << handler
      end

      # Attach an IPC event bus so that deep-link activations are also emitted
      # as `"deep-link"` events on the bus.
      #
      # The event payload is a JSON object with the keys:
      #   - `"url"` – the raw URL string
      #   - `"scheme"` – the URL scheme
      #   - `"host"` – the URL host
      #   - `"path"` – the URL path
      #   - `"params"` – a JSON object of query parameters
      def attach_router(router : IPC::Router) : Nil
        @router = router
      end

      # Register a callback that is invoked to bring the application window to
      # the foreground when a deep link is activated while the app is already
      # running.
      def on_foreground(&handler : ->) : Nil
        @foreground_handler = handler
      end

      # Mark the application as started and flush any URLs that arrived during
      # startup.
      #
      # Call this once the application's main window is ready to receive events.
      # Any deep links that were queued before this call will be dispatched now.
      def mark_started : Nil
        @started = true
        flush_startup_urls
      end

      # Returns true if the application has been marked as started.
      def started? : Bool
        @started
      end

      # Returns the list of URLs that are still pending in the startup queue.
      # Normally this is empty after `mark_started` has been called.
      def pending_startup_urls : Array(String)
        @startup_queue.dup
      end

      # Parse a deep link URL string into a `DeepLinkURL` struct.
      #
      # Raises `Core::ValidationError` if the URL cannot be parsed or the scheme
      # is not registered.
      def parse_url(url : String) : DeepLinkURL
        uri = URI.parse(url)

        scheme = uri.scheme
        if scheme.nil? || scheme.empty?
          raise Core::ValidationError.new(
            "Invalid deep link URL: missing scheme in '#{url}'",
            field: "scheme"
          )
        end

        host = uri.host || ""
        path = uri.path || ""
        query_params = parse_query_params(uri.query)

        DeepLinkURL.new(
          scheme: scheme,
          host: host,
          path: path,
          query_params: query_params,
          raw_url: url
        )
      rescue URI::Error
        raise Core::ValidationError.new(
          "Invalid deep link URL: '#{url}'",
          field: "url"
        )
      end

      # Handle a deep link URL activation (called by the platform layer or tests).
      #
      # Behaviour:
      # - If the application has not yet started (`mark_started` not called), the URL
      #   is queued and will be dispatched once `mark_started` is called (req 14.8).
      # - If the application is already running, the foreground handler is invoked
      #   first to bring the window to the front (req 14.3), then all `on_open`
      #   handlers are called (req 14.9), and a `"deep-link"` event is emitted on
      #   the attached IPC event bus if one is set (req 14.4).
      # - If the scheme is not registered, a warning is logged and the URL is ignored.
      def handle_url(url : String) : Nil
        # Queue during startup if not yet started
        unless @started
          @startup_queue << url
          Log.debug { "DeepLink: queued startup URL '#{url}'" }
          return
        end

        dispatch_url(url)
      end

      # Validate a scheme string against the allowed format.
      #
      # Raises `Core::ValidationError` if invalid.
      def validate_scheme!(scheme : String) : Nil
        if scheme.empty?
          raise Core::ValidationError.new(
            "URL scheme cannot be empty",
            field: "scheme"
          )
        end

        if scheme.size > SCHEME_MAX_LENGTH
          raise Core::ValidationError.new(
            "URL scheme '#{scheme}' exceeds maximum length of #{SCHEME_MAX_LENGTH} characters",
            field: "scheme"
          )
        end

        unless SCHEME_PATTERN.matches?(scheme)
          raise Core::ValidationError.new(
            "URL scheme '#{scheme}' is invalid: must contain only alphanumeric characters (a-z, A-Z, 0-9)",
            field: "scheme"
          )
        end
      end

      # Flush all URLs that were queued during startup.
      # :nodoc:
      private def flush_startup_urls : Nil
        queued = @startup_queue.dup
        @startup_queue.clear
        queued.each do |url|
          Log.debug { "DeepLink: flushing startup URL '#{url}'" }
          dispatch_url(url)
        end
      end

      # Core dispatch logic: parse the URL, invoke the foreground handler, call
      # all `on_open` handlers, and emit an IPC event.
      # :nodoc:
      private def dispatch_url(url : String) : Nil
        deep_link = parse_url(url)

        unless registered?(deep_link.scheme)
          Log.warn { "DeepLink: received URL for unregistered scheme '#{deep_link.scheme}'" }
          return
        end

        # Bring the application to the foreground
        if handler = @foreground_handler
          begin
            handler.call
          rescue ex
            Log.error { "DeepLink: foreground handler raised an error: #{ex.message}" }
          end
        end

        # Emit IPC event with the URL details
        if router = @router
          begin
            params_json = JSON::Any.new(
              deep_link.query_params.transform_values { |v| JSON::Any.new(v) }
            )
            payload = JSON::Any.new({
              "url"    => JSON::Any.new(deep_link.raw_url),
              "scheme" => JSON::Any.new(deep_link.scheme),
              "host"   => JSON::Any.new(deep_link.host),
              "path"   => JSON::Any.new(deep_link.path),
              "params" => params_json,
            })
            router.emit_event(DEEP_LINK_EVENT, payload)
          rescue ex
            Log.error { "DeepLink: failed to emit IPC event for '#{url}': #{ex.message}" }
          end
        end

        @open_handlers.each do |handler_inner|
          begin
            handler_inner.call(deep_link)
          rescue ex
            Log.error { "DeepLink: handler raised an error for '#{url}': #{ex.message}" }
          end
        end
      end

      # Parse a URI query string into a hash of key-value pairs.
      # :nodoc:
      private def parse_query_params(query : String?) : Hash(String, String)
        params = Hash(String, String).new
        return params if query.nil? || query.empty?

        query.split("&").each do |pair|
          parts = pair.split("=", 2)
          key = URI.decode_www_form(parts[0])
          value = parts.size > 1 ? URI.decode_www_form(parts[1]) : ""
          params[key] = value unless key.empty?
        end

        params
      end
    end
  end
end
