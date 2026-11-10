require "json"
require "log"
require "uri"
require "../core/errors"

module CrystKit
  module Features
    # Enumeration of sensitive capabilities the application may request access to.
    #
    # Each value corresponds to a discrete platform resource (e.g. camera,
    # microphone, geolocation).
    enum PermissionType
      Camera
      Microphone
      Geolocation
      Notifications
      ScreenCapture
      Fullscreen
      PointerLock
      ClipboardRead
      ClipboardWrite
      LocalFonts
      FileSystem
      WindowManagement
    end

    # State a capability may resolve to.
    #
    # `Granted` and `Denied` are terminal decisions; `Prompt` indicates no
    # decision has been made yet.
    enum PermissionState
      Granted
      Denied
      Prompt
    end

    # Mutable description of a permission request being processed.
    #
    # Handlers may mutate `state` to influence the decision; any non-`Prompt`
    # value takes precedence over persisted state and defaults.
    class PermissionRequest
      getter type : PermissionType
      getter origin : URI
      getter window_label : String?
      property state : PermissionState

      def initialize(@type : PermissionType, @origin : URI, @window_label = nil)
        @state = PermissionState::Prompt
      end
    end

    # Mediates permission decisions between web content and the host OS.
    #
    # Resolution order for `handle_request`:
    # 1. Invoke every `on_request` handler with a fresh `PermissionRequest`.
    #    If a handler set a non-`Prompt` state, return that immediately.
    # 2. Look up the persisted decision for the (origin, type) pair.
    # 3. Fall back to the per-type default registered via `set_default`,
    #    `grant`, or `deny`.
    #
    # All public mutations and reads are thread-safe.
    class Permissions
      Log = ::Log.for(self)

      # Separator used when encoding origin and type into a persisted key.
      # Must not appear in either component.
      KEY_SEPARATOR = "::"

      @handlers : Array(Proc(PermissionRequest, Nil))
      @defaults : Hash(PermissionType, PermissionState)
      @persisted : Hash(String, PermissionState)
      @persist_path : Path
      @mutex : Mutex

      def initialize(storage_dir : Path = Path[Dir.current] / ".crystkit" / "permissions")
        @handlers = [] of Proc(PermissionRequest, Nil)
        @defaults = Hash(PermissionType, PermissionState).new { PermissionState::Prompt }
        @persisted = Hash(String, PermissionState).new
        @persist_path = storage_dir / "permissions.json"
        @mutex = Mutex.new
        load_persisted
      end

      # Register a handler invoked synchronously during `handle_request`.
      #
      # Handlers may mutate `PermissionRequest#state` to influence the
      # decision. Called in registration order.
      def on_request(&block : PermissionRequest -> Nil) : Nil
        @handlers << block
      end

      # Override the default state returned when no handler or persisted
      # value resolves the request for *type*.
      def set_default(type : PermissionType, state : PermissionState) : Nil
        @defaults[type] = state
      end

      # Convenience for `set_default(type, PermissionState::Granted)`.
      def grant(type : PermissionType) : Nil
        @defaults[type] = PermissionState::Granted
      end

      # Convenience for `set_default(type, PermissionState::Denied)`.
      def deny(type : PermissionType) : Nil
        @defaults[type] = PermissionState::Denied
      end

      # Resolve the effective `PermissionState` for the given request.
      #
      # The *window_label* is informational and may be used by handlers for
      # context. Resolution order is described in the class documentation.
      # Returns `PermissionState::Prompt` if no source produced a value
      # *and* the default for the type is `Prompt`.
      def handle_request(type : PermissionType, origin : URI, window_label : String? = nil) : PermissionState
        req = PermissionRequest.new(type, origin, window_label)

        @mutex.synchronize do
          @handlers.each(&.call(req))
        end

        return req.state unless req.state.prompt?

        key = perm_key(origin, type)
        @mutex.synchronize do
          return @persisted[key] if @persisted.has_key?(key)
        end

        @defaults[type]
      end

      # Persist a decision so that future `handle_request` calls for the
      # same origin/type bypass handler dispatch.
      #
      # Failures are logged but not raised.
      def persist(origin : URI, type : PermissionType, state : PermissionState) : Nil
        @mutex.synchronize do
          @persisted[perm_key(origin, type)] = state
          save_persisted
        end
      end

      # Return the configured default state for *type*, ignoring handler and
      # persisted state.
      def default(type : PermissionType) : PermissionState
        @defaults[type]
      end

      # Return the persisted state for the (origin, type) pair, or `nil` if
      # nothing has been persisted for that pair.
      def persisted_state(origin : URI, type : PermissionType) : PermissionState?
        @mutex.synchronize do
          @persisted[perm_key(origin, type)]?
        end
      end

      # :nodoc:
      private def perm_key(origin : URI, type : PermissionType) : String
        "#{origin}#{KEY_SEPARATOR}#{type}"
      end

      # :nodoc:
      private def parse_key(key : String) : {URI, PermissionType}?
        parts = key.split(KEY_SEPARATOR, 2)
        return nil unless parts.size == 2
        origin = URI.parse(parts[0])
        ptype = PermissionType.parse?(parts[1])
        return nil unless ptype
        {origin, ptype}
      end

      # :nodoc:
      private def load_persisted : Nil
        return unless File.exists?(@persist_path)
        data = File.read(@persist_path)
        parsed = JSON.parse(data)
        parsed.as_h.each do |key, val|
          parsed_key = parse_key(key)
          if parsed_key
            _origin, _ptype = parsed_key
            state = PermissionState.parse?(val.as_s)
            @persisted[key] = state if state
          end
        end
      rescue ex
        Log.warn { "Failed to load persisted permissions: #{ex.message}" }
      end

      # :nodoc:
      private def save_persisted : Nil
        dir = @persist_path.parent
        Dir.mkdir_p(dir.to_s) unless Dir.exists?(dir.to_s)
        data = @persisted.to_json
        File.write(@persist_path, data)
      rescue ex
        Log.warn { "Failed to save persisted permissions: #{ex.message}" }
      end
    end
  end
end
