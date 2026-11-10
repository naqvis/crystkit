require "../base"
require "../../features/window_state"

module CrystKit
  module Plugins
    # Builtin plugin that persists and restores per-window state (position,
    # size, maximized, fullscreen, visible) across application restarts.
    #
    # On window creation the plugin auto-restores the saved geometry
    # (respecting the configured tracking flags) and installs lifecycle hooks
    # that capture live state changes; on shutdown it flushes a final snapshot
    # of every non-denylisted window to disk.
    #
    # Registers IPC commands:
    #   ws:save — Save window state (position, size, maximized, fullscreen, visible)
    #   ws:restore — Restore saved window state by ID
    #   ws:clear — Clear saved window state by ID
    #   ws:save_all — Flush in-memory cache to disk
    #
    # Also auto-restores window state on window creation and
    # auto-saves on close via lifecycle hooks.
    #
    # Required capability: `ws:manage`
    #
    # Per-plugin config keys: `filename` (state file name, default
    # `.window-state.json`), `denylist` (window labels to skip),
    # `skip_initial_state` (labels to restore-on-create but still track), and
    # `track` (a `{size, position, maximized, visible, fullscreen}` object of
    # booleans, all defaulting to `true`).
    #
    # ```
    # app.plugin(CrystKit::Plugins::WState.new)
    # ```
    class WState < Plugin::Base
      # The on-disk window-state store, lazily initialized during
      # `#initialize_plugin`.
      @store : Features::WindowStateStore?

      # In-memory cache of per-label state objects used by the IPC commands.
      @states = {} of String => Features::WindowState

      # Config (extracted from context.config in initialize_plugin).
      #
      # The filename of the JSON state file within the app's storage dir,
      # defaulting to `.window-state.json`.
      @filename : String = ".window-state.json"

      # Config: window labels whose state should never be tracked or restored.
      @denylist : Array(String) = [] of String

      # Config: window labels to skip the initial restore-on-create for, while
      # still capturing their state through the lifecycle hooks.
      @skip_initial_state : Array(String) = [] of String

      # Config: whether to track window size. Defaults to `true`.
      @track_size : Bool = true

      # Config: whether to track window position. Defaults to `true`.
      @track_position : Bool = true

      # Config: whether to track the maximized flag. Defaults to `true`.
      @track_maximized : Bool = true

      # Config: whether to track the visible flag. Defaults to `true`.
      @track_visible : Bool = true

      # Config: whether to track the fullscreen flag. Defaults to `true`.
      @track_fullscreen : Bool = true

      # Returns the unique plugin identifier `"window_state"`.
      def identifier : String
        "window_state"
      end

      # Returns the metadata contract gating every state command behind the
      # `ws:manage` capability. The lifecycle hooks (`#on_window_created`,
      # the shutdown flush) are not exposed as IPC commands.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(ws.save ws.restore ws.clear ws.save_all), "ws:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(ws:manage),
          commands: %w(ws.save ws.restore ws.clear ws.save_all),
          ipc: ipc,
        )
      end

      # Registers the IPC commands and installs the shutdown flush hook.
      #
      # Config is read once at initialization. The store path is
      # `app.config.storage_dir/@filename`. `ws.save` takes a label and a JSON
      # state object; `ws.restore` returns the saved state or `nil`; `ws.clear`
      # drops a label's state; `ws.save_all` flushes the store. On shutdown the
      # plugin captures a final snapshot of every live window.
      def initialize_plugin(context : Plugin::Context) : Nil
        config = context.config

        @filename = config["filename"]?.try(&.as_s) || ".window-state.json"
        @denylist = config["denylist"]?.try(&.as_a).try(&.map(&.as_s)) || [] of String
        @skip_initial_state = config["skip_initial_state"]?.try(&.as_a).try(&.map(&.as_s)) || [] of String

        if track = config["track"]?
          @track_size = track["size"]?.try(&.as_bool) || true
          @track_position = track["position"]?.try(&.as_bool) || true
          @track_maximized = track["maximized"]?.try(&.as_bool) || true
          @track_visible = track["visible"]?.try(&.as_bool) || true
          @track_fullscreen = track["fullscreen"]?.try(&.as_bool) || true
        end

        storage_path = Path[context.app.config.storage_dir, @filename]

        @store = Features::WindowStateStore.new(storage_path)

        storage_dir = context.app.config.storage_dir

        get_state = ->(id : String) {
          @states[id] ||= Features::WindowState.new(id, storage_dir)
        }

        context.command "ws.save", String, JSON::Any do |id, state_json|
          state = Features::WindowStateData.new(
            x: state_json["x"]?.try(&.as_i) || 0,
            y: state_json["y"]?.try(&.as_i) || 0,
            width: state_json["width"]?.try(&.as_i) || 800,
            height: state_json["height"]?.try(&.as_i) || 600,
            maximized: state_json["maximized"]?.try(&.as_bool) || false,
            fullscreen: state_json["fullscreen"]?.try(&.as_bool) || false,
            prev_x: state_json["prev_x"]?.try(&.as_i) || 0,
            prev_y: state_json["prev_y"]?.try(&.as_i) || 0,
            visible: state_json["visible"]?.try(&.as_bool) || true,
          )
          get_state.call(id).save(state)
        end

        context.command "ws.restore", String do |id|
          state = get_state.call(id).restore
          if state
            {
              "x" => state.x, "y" => state.y,
              "width" => state.width, "height" => state.height,
              "maximized" => state.maximized?, "fullscreen" => state.fullscreen?,
              "prev_x" => state.prev_x, "prev_y" => state.prev_y,
              "visible" => state.visible?,
            }
          end
        end

        context.command "ws.clear", String do |id|
          get_state.call(id).clear
        end

        context.command "ws.save_all" do
          @store.try(&.flush)
        end

        context.app.on_shutdown { flush_all_states(context) }
      end

      # Auto-restores saved state for a newly created window and installs the
      # lifecycle capture hooks.
      #
      # Skips windows with no label or whose label is in the denylist. When a
      # saved state exists and the label is not in `skip_initial_state`, the
      # window is moved, sized, and (if applicable) maximized/fullscreened
      # according to the tracking flags — using `prev_x`/`prev_y` when the
      # saved state was maximized so the pre-maximize geometry is restored.
      # The `close`/`minimize`/`maximize`/`restore`/`move`/`resize` hooks then
      # keep the cache in sync for the lifetime of the window.
      def on_window_created(window : ::CrystKit::Core::Window) : Nil
        label = window.label
        return unless label
        return if @denylist.includes?(label)

        store = @store
        return unless store

        unless @skip_initial_state.includes?(label)
          saved = store[label]?
          if saved
            maxed = saved.maximized?
            x = maxed ? saved.prev_x : saved.x
            y = maxed ? saved.prev_y : saved.y
            window.move(x, y) if @track_position
            window.size(saved.width, saved.height) if @track_size
            window.maximize if @track_maximized && maxed
            window.fullscreen = saved.fullscreen? if @track_fullscreen
          end
        end

        window.on("close") { capture_state(window, label) }
        window.on("minimize") { update_cache_boolean(label, :maximized, false) }
        window.on("maximize") { capture_and_set_maximized(window, label) }
        window.on("restore") { update_cache_boolean(label, :maximized, false) }

        window.on("move") { capture_state(window, label) }
        window.on("resize") { capture_state(window, label) }
      end

      # :nodoc: Snapshots the live geometry/flags of *window* into the store
      # under *label*, honoring the tracking flags.
      #
      # Reuses an existing state entry when present, otherwise starts from a
      # default `WindowStateData`. Only the tracked dimensions are updated.
      private def capture_state(window, label)
        store = @store
        return unless store && label

        state = store[label]? || Features::WindowStateData.new
        if @track_position
          pos = window.position
          state.x = pos[0]
          state.y = pos[1]
        end
        state.width = window.width if @track_size
        state.height = window.height if @track_size
        state.maximized = window.native.maximized? if @track_maximized
        state.fullscreen = window.native.fullscreen? if @track_fullscreen
        state.visible = window.visible? if @track_visible
        store[label] = state
      end

      # :nodoc: Records a maximize transition, stashing the pre-maximize
      # position into `prev_x`/`prev_y` so a later restore-on-create can
      # recover the un-maximized geometry.
      private def capture_and_set_maximized(window, label)
        store = @store
        return unless store && label

        state = store[label]? || Features::WindowStateData.new
        if @track_position
          state.prev_x = state.x
          state.prev_y = state.y
        end
        state.maximized = true
        store[label] = state
      end

      # :nodoc: Patches a single boolean field on an existing cached state
      # entry. Used by the `minimize`/`restore` hooks to flip `maximized` off
      # without re-snapshotting the full geometry. No-ops when no entry exists.
      private def update_cache_boolean(label, field : Symbol, value : Bool)
        store = @store
        return unless store

        state = store[label]?
        return unless state

        state.maximized = value if field == :maximized
      end

      # :nodoc: Final shutdown hook: captures the current state of every
      # non-denylisted live window and flushes the store to disk.
      private def flush_all_states(context)
        store = @store
        return unless store

        context.app.window_registry.all.each do |window|
          label = window.label
          next unless label
          next if @denylist.includes?(label)
          capture_state(window, label)
        end

        store.flush
      end
    end
  end
end
