require "json"
require "log"
require "../core/errors"

module CrystKit::Features
  # Persisted window state. Serializable via `JSON::Serializable`.
  class WindowStateData
    include JSON::Serializable

    # Window x position in logical screen coordinates.
    property x : Int32
    # Window y position in logical screen coordinates.
    property y : Int32
    # Window width in logical pixels.
    property width : Int32
    # Window height in logical pixels.
    property height : Int32
    # Whether the window was maximized when last persisted.
    property? maximized : Bool
    # Whether the window was in fullscreen mode when last persisted.
    property? fullscreen : Bool
    # Saved pre-maximization x position, used to restore normal geometry.
    property prev_x : Int32 = 0
    # Saved pre-maximization y position, used to restore normal geometry.
    property prev_y : Int32 = 0
    # Whether the window was visible when last persisted.
    property? visible : Bool = true

    # Creates a window-state record with sensible defaults (an 800x600
    # window at the origin, not maximized, not fullscreen, visible).
    def initialize(
      @x = 0,
      @y = 0,
      @width = 800,
      @height = 600,
      @maximized = false,
      @fullscreen = false,
      @prev_x = 0,
      @prev_y = 0,
      @visible = true,
    )
    end
  end

  # Manages window state persistence (position, size, maximized, fullscreen, display).
  #
  # State for a single window identified by *window_id* is stored in a
  # shared JSON file (`window_states.json`) keyed by window id, so
  # multiple windows managed by the same application coexist in one
  # file. For high-frequency updates prefer the in-memory
  # `WindowStateStore` and flush explicitly.
  class WindowState
    @window_id : String
    @storage_path : Path

    # Creates a state manager for the window identified by *window_id*.
    #
    # When *storage_dir* is `nil` the manager defaults to a temp
    # directory (`<tmpdir>/webview_app`); pass an explicit app-data
    # directory for production use so state survives temp cleanup.
    def initialize(@window_id : String, storage_dir : Path? = nil)
      dir = storage_dir || default_storage_dir
      @storage_path = dir / "window_states.json"
    end

    # Saves the given *state* to disk under this window's id.
    # Other windows' entries are preserved.
    def save(state : WindowStateData) : Nil
      all_states = load_all_states
      all_states[@window_id] = state
      persist(all_states)
    end

    # Restores the saved state for this window.
    #
    # Returns the persisted `WindowStateData`, or `nil` if no state is
    # saved for this window or the saved position/size fails validation
    # (e.g. off-screen or non-positive dimensions).
    def restore : WindowStateData?
      all_states = load_all_states
      state = all_states[@window_id]?
      return nil unless state
      validate_state(state) ? state : nil
    end

    # Deletes the saved state for this window. Other windows' entries
    # are preserved.
    def clear : Nil
      all_states = load_all_states
      all_states.delete(@window_id)
      persist(all_states)
    end

    # Saves state via a *capture* block that returns the current
    # `WindowStateData`. Convenience for "save on close" wiring.
    def auto_save(&capture : -> WindowStateData)
      save(capture.call)
    end

    # Restores state, returning the saved state or `nil`.
    #
    # The application is responsible for applying the returned geometry
    # to its window. Symmetric counterpart to `#auto_save`.
    def auto_restore : WindowStateData?
      restore
    end

    # :nodoc:
    private def validate_state(state : WindowStateData) : Bool
      # Reject obviously off-screen positions
      # A position is considered off-screen if both x and y are extremely negative
      return false if state.x < -10_000 || state.y < -10_000
      return false if state.width <= 0 || state.height <= 0
      true
    end

    # :nodoc:
    private def load_all_states : Hash(String, WindowStateData)
      return Hash(String, WindowStateData).new unless File.exists?(@storage_path.to_s)

      begin
        content = File.read(@storage_path.to_s)
        Hash(String, WindowStateData).from_json(content)
      rescue ex
        Log.warn { "WindowState: failed to load states from #{@storage_path}: #{ex.message}" }
        Hash(String, WindowStateData).new
      end
    end

    # :nodoc:
    private def persist(states : Hash(String, WindowStateData)) : Nil
      Dir.mkdir_p(@storage_path.parent.to_s) unless Dir.exists?(@storage_path.parent.to_s)
      File.write(@storage_path.to_s, states.to_json)
    rescue ex
      Log.error { "WindowState: failed to save states to #{@storage_path}: #{ex.message}" }
    end

    # :nodoc:
    private def default_storage_dir : Path
      # Use a temp-like directory for the default; real apps would use app data dir
      Path[Dir.tempdir] / "webview_app"
    end
  end

  # In-memory cache of window states. Read and mutate entries via
  # hash-style indexing, then flush to disk with `#flush`.
  class WindowStateStore
    Log = ::Log.for(self)

    @cache : Hash(String, WindowStateData)

    # Creates a store for the JSON file at *path*. A missing or
    # unparseable file yields an empty cache (logged at warn level)
    # rather than raising.
    def initialize(@path : Path)
      @cache = load_from_disk
    end

    # Returns the state for window *id*, or `nil` if none is cached.
    def []?(id : String) : WindowStateData?
      @cache[id]?
    end

    # Returns the state for window *id*.
    #
    # Raises `KeyError` if *id* is not in the cache.
    def [](id : String) : WindowStateData
      @cache[id]
    end

    # Stores *state* under window *id*, returning *state*. Held in
    # memory only until `#flush` is called.
    def []=(id : String, state : WindowStateData) : WindowStateData
      @cache[id] = state
    end

    # Removes the state for window *id* from the cache. No-op when *id*
    # is not present. The deletion is in-memory only until `#flush`.
    def delete(id : String) : Nil
      @cache.delete(id)
    end

    # Flushes the in-memory cache to disk. Creates the parent
    # directory if needed. I/O errors are logged at error level rather
    # than raised.
    def flush : Nil
      Dir.mkdir_p(@path.parent.to_s) unless Dir.exists?(@path.parent.to_s)
      File.write(@path.to_s, @cache.to_json)
    rescue ex
      Log.error { "WindowStateStore: failed to flush to #{@path}: #{ex.message}" }
    end

    # :nodoc:
    private def load_from_disk : Hash(String, WindowStateData)
      return Hash(String, WindowStateData).new unless File.exists?(@path.to_s)

      content = File.read(@path.to_s)
      Hash(String, WindowStateData).from_json(content)
    rescue ex
      Log.warn { "WindowStateStore: failed to load from #{@path}: #{ex.message}" }
      Hash(String, WindowStateData).new
    end
  end
end
