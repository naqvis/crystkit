require "../base"
require "../../platform/interface"

{% if flag?(:darwin) %}
  require "../../platform/macos/nspanel"
{% end %}

module CrystKit
  module Plugins
    # NSPanel plugin — automatically converts every enhanced window into a
    # floating NSPanel on macOS. Just install it:
    #
    # ```
    # app.plugin(CrystKit::Plugins::NSPanel.new)
    # ```
    #
    # Every enhanced window created after installation is auto-converted.
    # The defaults give a borderless floating panel. Override per-window
    # by passing a config hash to the constructor.
    #
    # ```
    # app.plugin(CrystKit::Plugins::NSPanel.new({
    #   "overlay" => CrystKit::Plugins::NSPanel::PanelOptions.new(
    #     style_mask: CrystKit::Plugins::NSPanel::Mask::NonactivatingPanel,
    #     level: CrystKit::Plugins::NSPanel::Level::Floating,
    #   ),
    # }))
    # ```
    #
    # On non-macOS targets the plugin installs as a no-op that only emits a
    # warning, so the same registration line is safe to ship cross-platform.
    # The macOS-only types (`PanelOptions`, `Level`, `Mask`, `Behavior`,
    # `Panel`) are compiled in only on Darwin and are absent elsewhere.
    class NSPanel < Plugin::Base
      # Returns the unique plugin identifier `"nspanel"`.
      def identifier : String
        "nspanel"
      end

      # Returns the minimal metadata contract for this plugin: no IPC commands,
      # capabilities, or events. Work happens through `#on_window_created`.
      def metadata : Plugin::Metadata
        Plugin::Metadata.new(
          identifier,
        )
      end

      # Initializes the plugin.
      #
      # On macOS this is a logging no-op; the actual conversion happens in
      # `#on_window_created`. On other platforms it logs that the plugin is
      # unsupported, so installs are safe but inert.
      def initialize_plugin(context : Plugin::Context) : Nil
        {% if flag?(:darwin) %}
          Log.debug { "NSPanel[plugin]: initialized" }
        {% else %}
          Log.warn { "NSPanel plugin is only supported on macOS" }
        {% end %}
      end

      {% if flag?(:darwin) %}
        # Short alias for the macOS platform module, used to reference
        # `Platform::MacOS::Panel` and `Platform::MacOS::ObjCRuntime` without
        # the full qualifier inside this plugin.
        alias MacOS = ::CrystKit::Platform::MacOS

        # Per-window panel configuration passed to `NSPanel.new`.
        #
        # All fields are nilable — unset fields fall back to NSPanel defaults
        # and are skipped during `#on_window_created` so the native panel keeps
        # its inherited behavior. Only the fields an application explicitly
        # sets are applied, which lets callers override a single attribute
        # (e.g. just `level`) without restating the rest.
        class PanelOptions
          # The NSPanel style mask (bitfield of `Mask` constants). Controls
          # panel chrome such as borderless, HUD, or utility appearance.
          property style_mask : UInt64?

          # Window level (`Level` constant) determining z-order relative to
          # other windows. Higher values float above lower ones.
          property level : Int64?

          # Whether the panel floats above non-floating windows of the same
          # level. Maps to the panel's `isFloatingPanel` state.
          property floating : Bool?

          # When true the panel ignores all mouse events, letting clicks pass
          # through to windows below. Useful for overlay HUDs.
          property ignores_mouse_events : Bool?

          # When true the panel background is fully transparent; the webview
          # is responsible for painting visible content.
          property transparent : Bool?

          # When true the titlebar is drawn transparently over the content,
          # producing a seamless chrome-less look.
          property titlebar_transparent : Bool?

          # When true the panel can be dragged by clicking anywhere in its
          # background, not just the titlebar.
          property movable_by_background : Bool?

          # Drag interaction mode: `:standard` (default) or `:background`
          # (background-initiated dragging via a tracking area).
          property drag_mode : Symbol?

          # Whether the panel casts a drop shadow. Disable for flat overlays
          # composited against the desktop.
          property has_shadow : Bool?

          # `Behavior` bitfield controlling Spaces and full-screen participation
          # (e.g. join all spaces, stay stationary).
          property collection_behavior : Int64?

          # When true the panel remains interactive while a modal dialog is
          # running, useful for floating palettes.
          property works_when_modal : Bool?

          # When true the panel becomes the key window only when an element
          # inside it actually needs keyboard focus.
          property becomes_key_only_if_needed : Bool?

          # When true the panel is hidden automatically when the app
          # deactivates (loses focus), mirroring inspector/panel convention.
          property hides_on_deactivate : Bool?

          # When true the panel receives `mouseMoved` events for hover
          # tracking inside its content.
          property accepts_mouse_moved_events : Bool?

          # Window alpha in `[0.0, 1.0]`. Values below 1 render the panel
          # semi-transparent.
          property alpha : Float64?

          # Corner radius applied to the panel content area for rounded
          # corners. Ignored when the style mask already implies rounded
          # corners.
          property corner_radius : Float64?

          # When true a mouse tracking area is installed so the panel
          # activates on hover without requiring a click.
          property hover_activate : Bool?

          # Creates a panel options bundle with every field left at its
          # NSPanel default.
          #
          # All arguments default to `nil`; pass only the fields you want to
          # override. `#on_window_created` skips `nil` fields when applying
          # the options to a converted panel.
          def initialize(
            @style_mask = nil,
            @level = nil,
            @floating = nil,
            @ignores_mouse_events = nil,
            @transparent = nil,
            @titlebar_transparent = nil,
            @movable_by_background = nil,
            @drag_mode = nil,
            @has_shadow = nil,
            @collection_behavior = nil,
            @works_when_modal = nil,
            @becomes_key_only_if_needed = nil,
            @hides_on_deactivate = nil,
            @accepts_mouse_moved_events = nil,
            @alpha = nil,
            @corner_radius = nil,
            @hover_activate = nil,
          )
          end
        end

        # Window level constants mapping to AppKit's `NSWindowLevel` values.
        #
        # Use these as `PanelOptions#level` to control z-order. Higher levels
        # float above lower ones; `Floating` is the typical choice for
        # panels, while `Status` and above sit above standard windows.
        module Level
          # Standard window level; the panel behaves like a normal window.
          Normal = 0_i64
          # Above standard windows; the default for floating panels.
          Floating = 4_i64
          # Above floating windows; used for modal panels.
          ModalPanel = 8_i64
          # Status-bar-level windows, above the main menu.
          Status = 25_i64
          # Pop-up menu level, above status windows.
          PopUpMenu = 101_i64
          # Screen-saver level, above everything else.
          ScreenSaver = 1000_i64
        end

        # Style mask constants combined via bitwise OR to set panel chrome.
        #
        # Pass a mask (or a combination) to `PanelOptions#style_mask` to
        # control the panel's appearance. `Borderless` and `Empty` are both
        # zero and produce a plain borderless panel.
        module Mask
          # No style bits set (borderless).
          Empty = 0_u64
          # The panel never activates the app when clicked — ideal for
          # floating tools that should not steal focus.
          NonactivatingPanel = MacOS::Panel::NS_NONACTIVATING_PANEL_MASK
          # Heads-up display style: dark, translucent, utility appearance.
          HUDWindow = MacOS::Panel::NS_HUD_WINDOW_MASK
          # Utility window style with a thinner titlebar.
          UtilityWindow = MacOS::Panel::NS_UTILITY_WINDOW_MASK
          # Alias for `Empty`; produces a borderless panel.
          Borderless = 0_u64
        end

        # Collection behavior constants controlling how the panel participates
        # in Spaces and full-screen modes.
        #
        # Pass a value to `PanelOptions#collection_behavior` (combine bits as
        # needed) to decide whether the panel follows the active Space, stays
        # stationary across Spaces, or joins full-screen windows.
        module Behavior
          # Default behavior; the panel follows standard Space rules.
          Default = MacOS::Panel::NSWindowCollectionBehaviorDefault
          # The panel is visible on all Spaces.
          CanJoinAllSpaces = MacOS::Panel::NSWindowCollectionBehaviorCanJoinAllSpaces
          # The panel may accompany full-screen windows as an auxiliary.
          FullScreenAuxiliary = MacOS::Panel::NSWindowCollectionBehaviorFullScreenAuxiliary
          # The panel may itself be the primary window in a full-screen Space.
          FullScreenPrimary = MacOS::Panel::NSWindowCollectionBehaviorFullScreenPrimary
          # The panel does not move with Space changes.
          Stationary = MacOS::Panel::NSWindowCollectionBehaviorStationary
          # The panel is excluded from the window cycling (Cmd-~) order.
          IgnoresCycle = MacOS::Panel::NSWindowCollectionBehaviorIgnoresCycle
        end

        # Wraps a native NSPanel handle with Crystal-idiomatic methods.
        #
        # Created by `NSPanel#on_window_created` and registered in `@@panels`
        # keyed by window label. After `#restore` the handle is nulled and the
        # panel is no longer valid; subsequent calls must be guarded by
        # `#valid?`.
        class Panel
          # The window label this panel was converted from, used as the
          # registry key in `@@panels` and to restore the original window.
          getter label : String

          # The raw native `NSPanel` handle. Becomes a null pointer after
          # `#restore`; check `#valid?` before passing to other APIs.
          getter handle : Void*

          # Creates a panel wrapper around the native *handle* tagged with
          # the originating window *label*.
          #
          # The *handle* is expected to be a live `NSPanel` pointer returned
          # by `Platform::MacOS::Panel.ns_window_to_panel`. The *label* is
          # later used by `#restore` to find the panel in the platform
          # registry and convert it back to a window.
          def initialize(@handle : Void*, @label : String)
          end

          # -- Visibility --

          # Orders the panel to the front and makes it visible without
          # activating the application.
          def show : Nil
            MacOS::Panel.panel_show(@handle)
          end

          # Removes the panel from the screen without destroying it.
          def hide : Nil
            MacOS::Panel.panel_hide(@handle)
          end

          # Shows the panel and makes it the key window so it receives
          # keyboard input.
          def show_and_make_key : Nil
            MacOS::Panel.panel_show_and_make_key(@handle)
          end

          # Orders the panel to the front regardless of activation state,
          # useful for non-activating panels that must appear above other
          # windows without stealing focus.
          def order_front : Nil
            MacOS::Panel.panel_order_front_regardless(@handle)
          end

          # -- Window state --

          # Makes the panel the current key window.
          def make_key : Nil
            MacOS::Panel.panel_make_key(@handle)
          end

          # Resigns key window status from the panel, returning keyboard
          # focus to the previous key window.
          def resign_key : Nil
            MacOS::Panel.panel_resign_key(@handle)
          end

          # -- Configuration --

          # Sets the window level controlling z-order. See `Level` for
          # semantic constants.
          def level=(value : Int64) : Nil
            MacOS::Panel.panel_set_level(@handle, value)
          end

          # Returns the current window level.
          def level : Int64
            MacOS::Panel.panel_level(@handle)
          end

          # Enables or disables floating behavior for the panel.
          def floating=(value : Bool) : Nil
            MacOS::Panel.panel_set_floating(@handle, value)
          end

          # Returns whether the panel is currently floating above
          # non-floating windows.
          def floating? : Bool
            MacOS::Panel.panel_is_floating(@handle)
          end

          # Replaces the panel's style mask (see `Mask` for bit constants).
          def style_mask=(mask : UInt64) : Nil
            MacOS::Panel.panel_set_style_mask(@handle, mask)
          end

          # Returns the currently applied style mask.
          def style_mask : UInt64
            MacOS::Panel.panel_style_mask(@handle)
          end

          # Sets the panel alpha in `[0.0, 1.0]`.
          def alpha=(value : Float64) : Nil
            MacOS::Panel.panel_set_alpha(@handle, value)
          end

          # Returns the current panel alpha value.
          def alpha : Float64
            MacOS::Panel.panel_alpha_value(@handle)
          end

          # When *value* is true the panel background is rendered fully
          # transparent.
          def transparent=(value : Bool) : Nil
            MacOS::Panel.panel_set_transparent(@handle, value)
          end

          # When *value* is true the panel ignores all mouse events, letting
          # clicks fall through to windows beneath.
          def ignores_mouse_events=(value : Bool) : Nil
            MacOS::Panel.panel_set_ignores_mouse_events(@handle, value)
          end

          # When *value* is true the titlebar is drawn transparently over the
          # panel content.
          def titlebar_transparent=(value : Bool) : Nil
            MacOS::Panel.panel_set_titlebar_appears_transparent(@handle, value)
          end

          # When *value* is true the panel can be dragged by its background
          # area, not just the titlebar.
          def movable_by_background=(value : Bool) : Nil
            MacOS::Panel.panel_set_movable_by_background(@handle, value)
          end

          # Sets the drag interaction mode (e.g. `:standard` or
          # `:background`).
          def drag_mode=(mode : Symbol) : Nil
            MacOS::Panel.panel_set_drag_mode(@handle, mode)
          end

          # Enables or disables the panel's drop shadow.
          def has_shadow=(value : Bool) : Nil
            MacOS::Panel.panel_set_has_shadow(@handle, value)
          end

          # Sets the collection behavior bitfield (see `Behavior`).
          def collection_behavior=(value : Int64) : Nil
            MacOS::Panel.panel_set_collection_behavior(@handle, value)
          end

          # When *value* is true the panel stays interactive while a modal
          # dialog is running.
          def works_when_modal=(value : Bool) : Nil
            MacOS::Panel.panel_set_works_when_modal(@handle, value)
          end

          # When *value* is true the panel is hidden automatically when the
          # application deactivates.
          def hides_on_deactivate=(value : Bool) : Nil
            MacOS::Panel.panel_set_hides_on_deactivate(@handle, value)
          end

          # When *value* is true the panel receives `mouseMoved` events for
          # hover tracking.
          def accepts_mouse_moved_events=(value : Bool) : Nil
            MacOS::Panel.panel_set_accepts_mouse_moved_events(@handle, value)
          end

          # Sets the corner radius applied to the panel content area.
          def corner_radius=(radius : Float64) : Nil
            MacOS::Panel.panel_set_corner_radius(@handle, radius)
          end

          # -- Query --

          # Returns whether the panel is currently visible on screen.
          def visible? : Bool
            MacOS::Panel.panel_is_visible(@handle)
          end

          # Returns whether the panel is allowed to become the key window.
          def can_become_key? : Bool
            MacOS::Panel.panel_can_become_key(@handle)
          end

          # Returns whether the panel is configured to hide on app
          # deactivation.
          def hides_on_deactivate? : Bool
            MacOS::Panel.panel_hides_on_deactivate(@handle)
          end

          # -- Lifecycle --

          # Converts the panel back to a regular `NSWindow` and nulls the
          # stored handle.
          #
          # After this call the receiver is no longer `#valid?` and must not
          # be used for further panel operations. The platform layer looks
          # up the panel by `#label` to perform the reverse conversion.
          def restore : Nil
            MacOS::Panel.panel_to_window(@label)
            @handle = Pointer(Void).null
          end

          # Returns whether the wrapper still holds a live native handle.
          def valid? : Bool
            !@handle.null?
          end
        end

        # -- Plugin-level state --

        # Registry of every converted panel keyed by window label.
        #
        # Populated by `#on_window_created` as windows are converted, and
        # queried via `.find`. Entries are removed by `.remove` or when the
        # window is destroyed (which calls `Panel.to_window` on the platform
        # side). Shared across all instances as class state.
        @@panels = {} of String => Panel

        # Default options applied to every window when no per-window config is
        # found in the constructor's `config` hash.
        #
        # Produces a borderless (`style_mask: 0`), floating (`level: 4`)
        # panel, which is the conventional starting point for overlay-style
        # panels. Override per window by passing a matching label entry to
        # `NSPanel.new`.
        DEFAULTS = PanelOptions.new(
          style_mask: 0_u64,
          level: 4_i64,
          floating: true,
        )

        # Optional `NSApplicationActivationPolicy` to apply when a window is
        # created, set via the constructor. `nil` leaves the policy unchanged.
        @activation_policy : Int64?

        # Creates the plugin with optional per-window configuration and an
        # application activation policy.
        #
        # *config* maps window labels to `PanelOptions`; windows whose label
        #   is present use that bundle, others fall back to `DEFAULTS`. Pass
        #   an empty hash (the default) to apply the defaults uniformly.
        # *activation_policy* — when set, the plugin sends
        #   `setActivationPolicy:` to the shared `NSApplication` for each
        #   created window, e.g. `0` for regular, `1` for accessory
        #   (menu-bar-less), `2` for background. Leave `nil` to keep the
        #   app's existing policy.
        def initialize(
          config : Hash(String, PanelOptions) = {} of String => PanelOptions,
          activation_policy : Int64? = nil,
        )
          @config = config
          @activation_policy = activation_policy
        end

        # Every enhanced window is auto-converted to an NSPanel when created.
        # Conversion is dispatched to the main thread.
        #
        # Failures during conversion are logged and the window is left as-is.
        def on_window_created(window : ::CrystKit::Core::Window) : Nil
          wv = window.native
          label = wv.label || ""
          options = @config[label]? || DEFAULTS
          start_hidden = !wv.visible?

          wv.dispatch do
            ns_window = wv.window
            if ns_window.null?
              Log.error { "NSPanel[plugin]: window handle null for '#{label}' in dispatch, giving up" }
              next
            end

            result = MacOS::Panel.ns_window_to_panel(ns_window, label)
            if result.null?
              Log.error { "NSPanel[plugin]: ns_window_to_panel returned null for '#{label}'" }
              next
            end

            panel = Panel.new(ns_window, label)
            @@panels[label] = panel

            if (v = options.style_mask)
              panel.style_mask = v
            end
            if (v = options.level)
              panel.level = v
            end
            if (v = options.floating)
              panel.floating = v
            end
            if (v = options.ignores_mouse_events)
              panel.ignores_mouse_events = v
            end
            if (v = options.transparent)
              panel.transparent = v
            end
            if (v = options.titlebar_transparent)
              panel.titlebar_transparent = v
            end
            if (v = options.movable_by_background)
              panel.movable_by_background = v
            end
            if (v = options.drag_mode)
              panel.drag_mode = v
            end
            if (v = options.has_shadow)
              panel.has_shadow = v
            end
            if (v = options.collection_behavior)
              panel.collection_behavior = v
            end
            if (v = options.works_when_modal)
              panel.works_when_modal = v
            end
            if (v = options.hides_on_deactivate)
              panel.hides_on_deactivate = v
            end
            if (v = options.accepts_mouse_moved_events)
              panel.accepts_mouse_moved_events = v
            end
            if (v = options.alpha)
              panel.alpha = v
            end
            if (v = options.corner_radius)
              panel.corner_radius = v
            end

            if options.hover_activate
              MacOS::Panel.panel_add_tracking_area(ns_window)
              Log.debug { "NSPanel[plugin]: hover activation enabled for '#{label}'" }
            end

            if start_hidden
              MacOS::Panel.panel_hide(ns_window)
            else
              MacOS::Panel.panel_order_front_regardless(ns_window)
            end

            Log.debug { "NSPanel[plugin]: converted '#{label}' to NSPanel" }
          end

          window.on("destroy") do
            MacOS::Panel.panel_to_window(label)
          end

          if policy = @activation_policy
            wv.dispatch do
              ns_app = MacOS::ObjCRuntime.msg(
                MacOS::ObjCRuntime.get_class("NSApplication"),
                "sharedApplication",
              )
              MacOS::ObjCRuntime.msg_int(ns_app, "setActivationPolicy:", policy)
            end
          end
        end

        # Retrieve a previously converted panel by *label*.
        #
        # Returns the registered `Panel`, or `nil` if no panel with that
        # label has been converted (or if it was already removed). The
        # returned wrapper may be `#valid? == false` if the panel was
        # restored back to a window.
        def self.find(label : String) : Panel?
          @@panels[label]?
        end

        # Remove a panel from the registry (does not destroy it).
        #
        # Deletes the entry from `@@panels` and asks the platform layer to
        # unregister the panel by *label*. The native panel itself is not
        # destroyed or restored to a window; use `Panel#restore` for that
        # before calling this to keep the platform registry consistent.
        def self.remove(label : String) : Nil
          @@panels.delete(label)
          MacOS::Panel.unregister_panel(label)
        end
      {% end %}
    end
  end
end
