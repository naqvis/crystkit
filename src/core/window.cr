require "uuid"
require "log"
require "./native_window"
require "../features/devtools"
require "../features/window_effects"
require "../features/window_state"
require "../features/toolbar"
require "../features/drag_source"

module CrystKit::Core
  # Application-facing surface for an application window.
  #
  # Covers geometry, visibility, lifecycle events, devtools, window
  # effects, and persisted state. The platform-native `EnhancedWindow`
  # is available via `#native` when a platform handle is needed.
  #
  # Create windows with `App#window` (which registers them) rather than
  # `Window.new` directly.
  #
  # Lifecycle events (`"focus"`, `"blur"`, `"move"`, `"resize"`, `"show"`,
  # `"hide"`, `"close"`, `"destroy"`, …) are observed via `#on`.
  #
  # ```
  # app.window(title: "Main", label: "main") do |win|
  #   win.on("resize") { |w| Log.info { "resized: #{w.width}x#{w.height}" } }
  #   win.eval("console.log('hello')")
  # end
  # ```
  class Window
    # :nodoc:
    Log = ::Log.for(self)

    # Stable, opaque, randomly-generated identifier for this window.
    # Never changes. Used as the primary key in `WindowRegistry` and
    # as the fallback label when no application label is supplied.
    getter id : String

    # Optional application-supplied identifier for this window, or
    # `nil` when none was provided. Must be unique within the registry.
    getter label : String?

    # Last known window title.
    getter title : String

    # Last known window width in pixels.
    getter width : Int32

    # Last known window height in pixels.
    getter height : Int32

    # Last known window x position in screen coordinates.
    getter x : Int32 = 0

    # Last known window y position in screen coordinates.
    getter y : Int32 = 0

    # Whether the window is currently visible.
    getter? visible : Bool

    # The platform-native `EnhancedWindow`.
    getter native : ::CrystKit::Core::EnhancedWindow
    @dispatch_eval : Proc(String, Nil)
    @lifecycle_handlers = {} of String => Array(Proc(Window, Nil))
    @effects : ::CrystKit::Features::WindowEffects?
    @devtools : ::CrystKit::Features::DevTools?
    @window_state : ::CrystKit::Features::WindowState?
    @toolbar : ::CrystKit::Features::Toolbar?
    @drag_source : ::CrystKit::Features::DragSource?

    # Creates a window with the given metadata. Application code
    # normally uses `App#window` instead, so the registry owns the
    # resulting instance.
    def initialize(
      native : ::CrystKit::Core::EnhancedWindow,
      @label = nil,
      @title = "Window",
      @width = 800,
      @height = 600,
      @visible = true,
      @id = UUID.random.to_s,
    )
      @native = native
      @dispatch_eval = ->(js : String) { native.dispatch { native.eval(js) } }
      attach_lifecycle(native)
    end

    # Returns the `WindowEffects` configured for this window, or `nil`
    # if none has been attached.
    def effects : ::CrystKit::Features::WindowEffects?
      @effects
    end

    # Attach a pre-built `WindowEffects` configuration to this window
    # and apply it immediately. Returns the assigned effects object.
    def effects=(effects : ::CrystKit::Features::WindowEffects) : ::CrystKit::Features::WindowEffects
      @effects = effects
      effects.apply(window)
      effects
    end

    # Build and attach a `WindowEffects` configuration inline, then
    # apply it. Returns the applied effects.
    #
    # ```
    # win.effects do |fx|
    #   fx.acrylic
    #   fx.rounded_corners(radius: 12)
    # end
    # ```
    def effects(&block : ::CrystKit::Features::WindowEffects ->) : ::CrystKit::Features::WindowEffects
      effects = ::CrystKit::Features::WindowEffects.new
      block.call(effects)
      self.effects = effects
    end

    # Returns the `DevTools` configuration for this window, or `nil`
    # if devtools have not been set up yet.
    def devtools : ::CrystKit::Features::DevTools?
      @devtools
    end

    # Attach a pre-built `DevTools` configuration to this window. This
    # does *not* open the devtools panel — call `#open_devtools` (or
    # `#toggle_devtools`) to do that.
    def devtools=(devtools : ::CrystKit::Features::DevTools) : ::CrystKit::Features::DevTools
      @devtools = devtools
    end

    # Build and attach a `DevTools` configuration inline. Returns the
    # attached instance.
    def devtools(&block : ::CrystKit::Features::DevTools ->) : ::CrystKit::Features::DevTools
      devtools = ::CrystKit::Features::DevTools.new
      block.call(devtools)
      self.devtools = devtools
    end

    # Open the devtools panel for this window.
    def open_devtools : Nil
      ensure_devtools.open(browser_controller_handle)
    end

    # Close the devtools panel for this window if it is open.
    def close_devtools : Nil
      ensure_devtools.close(browser_controller_handle)
    end

    # Toggle the devtools panel between open and closed.
    def toggle_devtools : Nil
      ensure_devtools.toggle(browser_controller_handle)
    end

    # Set the dock mode (docked side / undocked) for the devtools
    # panel.
    def devtools_dock_mode=(mode : ::CrystKit::Features::DevToolsDockMode) : Nil
      ensure_devtools.set_dock_mode(mode, browser_controller_handle)
    end

    # Returns the `WindowState` persistence helper attached to this
    # window, or `nil` if window-state persistence has not been
    # enabled.
    def window_state : ::CrystKit::Features::WindowState?
      @window_state
    end

    # Attach a pre-built `WindowState` helper to this window.
    #
    # Does not immediately restore or save — call
    # `#restore_window_state` / `#save_window_state` to drive
    # persistence. `#destroy` also saves automatically so state is
    # captured on close.
    def window_state=(window_state : ::CrystKit::Features::WindowState) : ::CrystKit::Features::WindowState
      @window_state = window_state
    end

    # Restore the persisted window geometry and visibility, if any.
    # Returns the restored `WindowStateData` (or `nil` when no state
    # was found).
    def restore_window_state : ::CrystKit::Features::WindowStateData?
      state = @window_state.try(&.restore)
      if state
        move(state.x, state.y)
        size(state.width, state.height)
        self.fullscreen = state.fullscreen?
        maximize if state.maximized?
        state.visible? ? show : hide
      end
      state
    end

    # Persist the current window geometry and visibility. No-op when no
    # `WindowState` helper is attached.
    def save_window_state : Nil
      return unless state = @window_state

      current_x, current_y = position
      state.save(::CrystKit::Features::WindowStateData.new(
        x: current_x,
        y: current_y,
        width: width,
        height: height,
        fullscreen: fullscreen?,
        visible: visible?,
      ))
    end

    def toolbar : ::CrystKit::Features::Toolbar?
      @toolbar
    end

    def toolbar=(tb : ::CrystKit::Features::Toolbar) : Nil
      @toolbar = tb if tb.install(self)
    end

    def toolbar(&block : ::CrystKit::Features::Toolbar ->) : ::CrystKit::Features::Toolbar
      bar = ::CrystKit::Features::Toolbar.new
      block.call(bar)
      self.toolbar = bar
      bar
    end

    def drag_source : ::CrystKit::Features::DragSource?
      @drag_source
    end

    def drag_source=(tb : ::CrystKit::Features::DragSource) : Nil
      @drag_source = tb
      @drag_source.attach(self)
    end

    def drag_source(&block : ::CrystKit::Features::DragSource ->) : ::CrystKit::Features::DragSource
      source = ::CrystKit::Features::DragSource.new
      block.call(source)
      self.drag_source = source
    end

    # Inject *js* to run once before each navigation's page script.
    def init(js : String) : Nil
      @native.init(js)
    end

    # Evaluate *js* in the page's main context.
    def eval(js : String) : Nil
      @native.eval(js)
    end

    # Run *block* on the window's UI thread.
    def dispatch(&block : ->) : Nil
      @native.dispatch { block.call }
    end

    # Bind a Crystal handler to a JS-callable global function *name*.
    # The handler receives raw JSON and returns `JSON::Any`.
    def bind(name : String, handler : ::Webview::JSProc) : Nil
      @native.bind(name, handler)
    end

    # Bind a typed Crystal handler to a JS-callable global function
    # *name*. The incoming JSON is decoded into *type* `T` and the
    # block's return value `R` is encoded back to JSON.
    def bind_typed(name : String, type : T.class, &block : T -> R) forall T, R
      @native.bind_typed(name, type, &block)
    end

    # Navigate the window to *url*.
    def navigate(url : String) : Nil
      @native.navigate(url)
    end

    # Replace the window's content with the given *html* document.
    def html=(html : String) : Nil
      @native.html = html
    end

    # Return a platform-native handle of *kind* for the underlying
    # webview. The concrete type of the returned pointer depends on
    # the requested kind and the host platform.
    def native_handle(kind : ::Webview::NativeHandleKind) : Void*
      @native.native_handle(kind)
    end

    # Return the OS window handle backing this webview. The returned
    # pointer is platform-specific (e.g. NSWindow on macOS, GtkWidget
    # on GTK, HWND on Windows).
    def window : Void*
      @native.window
    end

    # Whether this window was created with debug mode enabled.
    def debug? : Bool
      @native.debug?
    end

    # Terminate the webview's run loop. Typically called by
    # `App#quit`.
    def terminate : Nil
      @native.terminate
    end

    # Enable or disable minimize-to-tray behavior. When enabled,
    # closing the window hides it instead of destroying it.
    def minimize_to_tray=(value : Bool) : Nil
      @native.minimize_to_tray = value
    end

    # Register a handler invoked when the window is asked to
    # minimize to tray.
    def on_minimize_to_tray(&block : -> Nil) : Nil
      @native.on_minimize_to_tray(&block)
    end

    @user_close_handler : (-> Bool)?
    @native_close_handler_registered : Bool = false

    # Register a handler invoked when the user requests the window to
    # close.
    #
    # The block should return `true` to allow the close (the
    # `"close"` lifecycle event is emitted and the native window
    # proceeds) or `false` to veto it (the window stays open and no
    # lifecycle event is emitted). Replaces any previously
    # registered handler.
    def on_close(&handler : -> Bool) : Nil
      @user_close_handler = handler
      return if @native_close_handler_registered
      @native_close_handler_registered = true
      @native.on_close {
        result = @user_close_handler.try(&.call)
        if result != false
          emit_lifecycle("close")
          true
        else
          false
        end
      }
    end

    # Set the window title.
    def title=(value : String) : Nil
      @title = value
      @native.title = value
    end

    # Resize the window to *width*×*height* with the given *hint*,
    # then emit the `"resize"` lifecycle event.
    def size(width : Int32, height : Int32, hint : ::Webview::SizeHints = ::Webview::SizeHints::NONE) : Nil
      @width = width
      @height = height
      @native.size(width, height, hint)
      emit_lifecycle("resize")
    end

    # Bring the window to the foreground and emit the `"focus"`
    # lifecycle event.
    def focus : Nil
      @native.focus
      emit_lifecycle("focus")
    end

    # Return the window's current screen position as `{x, y}`. Falls back
    # to the last position observed through move events once the native
    # window has closed, so callers such as window-state persistence can
    # run during shutdown without touching freed native memory.
    def position : {Int32, Int32}
      return @native.position if @native.native_window_open?
      {@x, @y}
    end

    # Move the window to screen coordinates (*x*, *y*) and emit the
    # `"move"` lifecycle event.
    def move(x : Int32, y : Int32) : Nil
      @x = x
      @y = y
      @native.move(x, y)
      emit_lifecycle("move")
    end

    # Show the window, mark it visible, and emit the `"show"`
    # lifecycle event.
    def show : Nil
      @native.show
      @visible = true
      emit_lifecycle("show")
    end

    # Hide the window without destroying it, mark it not-visible,
    # and emit the `"hide"` lifecycle event.
    def hide : Nil
      @native.hide
      @visible = false
      emit_lifecycle("hide")
    end

    # Show the window at the current mouse cursor position, mark it
    # visible, and emit the `"show"` lifecycle event. Useful for
    # tray-triggered popovers and quicklook-style panels.
    def show_at_cursor : Nil
      @native.show_at_cursor
      @visible = true
      emit_lifecycle("show")
    end

    # Move the window by a relative (*x*, *y*) delta from its last
    # tracked position and emit the `"move"` lifecycle event.
    def move_by(x : Int32, y : Int32) : Nil
      @native.move_by(x, y)
      emit_lifecycle("move")
    end

    # Minimize the window to the taskbar/dock.
    def minimize : Nil
      @native.minimize
    end

    # Maximize the window.
    def maximize : Nil
      @native.maximize
    end

    # Restore the window from a minimized or maximized state.
    def restore : Nil
      @native.restore
    end

    # Toggle fullscreen mode on or off.
    def fullscreen=(value : Bool) : Nil
      @native.fullscreen = value
    end

    # Whether the window is currently in fullscreen mode.
    def fullscreen? : Bool
      @native.fullscreen?
    end

    # Toggle always-on-top z-order state.
    def always_on_top=(value : Bool) : Nil
      @native.always_on_top = value
    end

    # Whether always-on-top is currently enabled.
    def always_on_top? : Bool
      @native.always_on_top?
    end

    # Toggle modal state.
    def modal=(value : Bool) : Nil
      @native.modal = value
    end

    # Whether the window is in frameless (no OS title bar / frame)
    # mode.
    def frameless? : Bool
      @native.frameless?
    end

    # Toggle frameless mode.
    def frameless=(value : Bool) : Nil
      @native.frameless = value
    end

    # Current window opacity in the range `0.0` (transparent) to
    # `1.0` (opaque).
    def opacity : Float64
      @native.opacity
    end

    # Set the window opacity. Raises `ArgumentError` for
    # out-of-range values.
    def opacity=(value : Float64) : Nil
      @native.opacity = value
    end

    # Create a child `EnhancedWindow` parented to this one. The
    # returned child is *not* registered with the `WindowRegistry`;
    # use `App#window(options, parent_label:)` for full CrystKit
    # wiring.
    def create_child(options : ::CrystKit::Core::WindowOptions) : ::CrystKit::Core::EnhancedWindow
      @native.create_child(options)
    end

    # Subscribe to a lifecycle *event* on this window.
    #
    # *event* is a string name such as `"focus"`, `"blur"`, `"move"`,
    # `"resize"`, `"show"`, `"hide"`, `"close"`, or `"destroy"`.
    # Multiple handlers may be attached to the same event; they are
    # invoked in registration order.
    def on(event : String, &handler : Window -> Nil) : Nil
      (@lifecycle_handlers[event] ||= [] of Proc(Window, Nil)) << handler
    end

    # :nodoc:
    def emit_lifecycle(event : String) : Nil
      handlers = @lifecycle_handlers[event]?
      return unless handlers
      handlers.each do |handler|
        handler.call(self)
      rescue ex
        Log.error { "Lifecycle handler for '#{event}' failed: #{ex.message}" }
      end
    end

    # Destroy the window and release native resources.
    #
    # Emits the `"destroy"` lifecycle event first (while the window
    # is still usable), persists window state (when a `WindowState`
    # helper is attached), then tears down the native window. After
    # this returns the window is no longer usable.
    def destroy : Nil
      emit_lifecycle("destroy")
      save_window_state
      @toolbar.try(&.cleanup)
      @native.destroy
    end

    # Run the native window's event loop, blocking until the window
    # is closed or `#terminate` is called.
    def run : Nil
      @native.run
    end

    # :nodoc:
    def dispatch_eval(js : String) : Nil
      @dispatch_eval.call(js)
    end

    # :nodoc:
    private def attach_lifecycle(window : ::CrystKit::Core::EnhancedWindow) : Nil
      window.on_focus { emit_lifecycle("focus") }
      window.on_blur { emit_lifecycle("blur") }
      window.on_move { |x, y| @x = x; @y = y; emit_lifecycle("move") }
      window.on_resize { |width, height|
        @width = width
        @height = height
        emit_lifecycle("resize")
      }
      window.on_minimize { emit_lifecycle("minimize") }
      window.on_maximize { emit_lifecycle("maximize") }
      window.on_restore { emit_lifecycle("restore") }
    end

    # :nodoc:
    private def ensure_devtools : ::CrystKit::Features::DevTools
      @devtools ||= ::CrystKit::Features::DevTools.new
    end

    # :nodoc:
    private def browser_controller_handle : Void*
      native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER)
    end
  end
end
