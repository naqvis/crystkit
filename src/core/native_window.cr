require "webview"
require "native_desktop"
require "../ipc/js_bridge"
require "../platform/interface"

{% if flag?(:darwin) %}
  require "../platform/macos/enhanced_window"
{% elsif flag?(:linux) %}
  require "../platform/linux/enhanced_window"
{% elsif flag?(:windows) %}
  require "../platform/windows/bind_workaround"
  require "../platform/windows/enhanced_window"
{% end %}

module CrystKit
  module Core
    # Message-loop hook for embedding hosts that drive the webview's
    # message loop inside their own UI toolkit's run loop.
    #
    # When set, `EnhancedWindow#run` invokes the hook with the native
    # webview pointer instead of entering its default blocking run loop.
    module MessageLoopHook
      extend self

      @@hook : (Void* -> Nil)?

      # Returns the currently registered message-loop hook, or `nil` when
      # none has been set (the default).
      def get : (Void* -> Nil)?
        @@hook
      end

      # Register *handler* as the global message-loop hook. Only one hook
      # may be registered at a time; a subsequent call replaces the
      # previous one.
      def set(handler : Void* -> Nil)
        @@hook = handler
      end
    end

    # Options for constructing an `EnhancedWindow`.
    #
    # Accepted by `App#window(options:)` and `EnhancedWindow#create_child`.
    #
    # ```
    # opts = WindowOptions.new(
    #   title: "Settings",
    #   width: 480, height: 640,
    #   frameless: true,
    #   preload_scripts: ["window.__boot = true;"],
    # )
    # app.window(opts, parent_label: "main")
    # ```
    struct WindowOptions
      # Initial window width in pixels.
      property width : Int32

      # Initial window height in pixels.
      property height : Int32

      # Size hint (NONE, MIN, MAX, FIXED).
      property hint : ::Webview::SizeHints

      # Window title shown in the OS title bar (unless `#frameless?`).
      property title : String

      # Initial URL to navigate to, or `nil` to leave the window blank
      # until the caller navigates or sets HTML.
      property url : String?

      # When `true`, enables the webview's debug mode.
      property? debug : Bool

      # Optional application-supplied identifier used by
      # `WindowRegistry` for label-based lookups and by capability
      # enforcement to name window-scoped grants.
      property label : String?

      # When `true`, the window is created modal to its parent. Only
      # meaningful when the window is created as a child via
      # `parent_label`.
      property? modal : Bool

      # When `true`, the window floats above all other windows in
      # z-order.
      property? always_on_top : Bool

      # When `true`, the application is responsible for rendering its
      # own title bar and drag region in HTML/CSS.
      property? frameless : Bool

      # When `true`, the window background is rendered with an alpha
      # channel so the desktop can show through.
      property? transparent : Bool

      # Window opacity in the range `0.0` (fully transparent) to `1.0`
      # (fully opaque). Combine with `#transparent?` for a true alpha
      # background; on its own it composites the whole window.
      property opacity : Float64

      # Initial visibility. When `false`, the window is created hidden
      # so the caller can configure it before showing.
      property? visible : Bool = true

      # When `true`, closing the window hides it instead of destroying
      # it, leaving the process running in the system tray.
      property? minimize_to_tray : Bool = false

      # When `true`, the window starts in fullscreen mode.
      property? fullscreen : Bool = false

      # Optional initial x screen coordinate, or `nil` to let the OS
      # place the window.
      property x : Int32?

      # Optional initial y screen coordinate, or `nil` to let the OS
      # place the window.
      property y : Int32?

      # JavaScript snippets injected before each navigation's page
      # scripts run. Useful for framework bootstrap, polyfills, or
      # feature flags.
      property preload_scripts : Array(String) = [] of String

      # Optional per-window Content Security Policy override. When
      # non-nil and non-empty, it is injected as a `<meta>` tag instead
      # of the global `AppConfig#csp`. `nil` falls back to the global
      # CSP (if any).
      property csp : String? = nil

      # Creates a window-options value with the supplied geometry and
      # feature flags. All optional behavior defaults to off / nil so
      # an unmodified `WindowOptions.new` yields a plain 800×600 titled,
      # visible, opaque, non-modal, non-frameless window.
      def initialize(
        @width = 800,
        @height = 600,
        @hint = ::Webview::SizeHints::NONE,
        @title = "CrystKit",
        @url = nil,
        @debug = false,
        @label = nil,
        @modal = false,
        @always_on_top = false,
        @frameless = false,
        @transparent = false,
        @opacity = 1.0,
        @visible = true,
        @minimize_to_tray = false,
        @fullscreen = false,
        @x = nil,
        @y = nil,
        @preload_scripts : Array(String) = [] of String,
        @csp = nil,
      )
      end
    end

    # Platform-aware extension of `Webview::Webview` with focus management,
    # visibility, z-order, parent-child relationships, decorations,
    # transparency, and window event callbacks.
    #
    # This is the native layer of the window abstraction; application code
    # normally uses `Core::Window`, which exposes this via `#native`.
    #
    # The synchronous getters (`visible?`, `always_on_top?`,
    # `minimize_to_tray?`, `frameless?`, `transparent?`, `opacity`,
    # `fullscreen?`, `minimized?`, `maximized?`, `position`, `tracked_x`,
    # `tracked_y`) are safe from any thread; mutations are dispatched onto
    # the UI thread.
    class EnhancedWindow < ::Webview::Webview
      Log = ::Log.for("crystkit.core.native_window")
      include IPC::JSClientSetup
      {% if flag?(:win32) %}
        include CrystKit::WindowsBindWorkaround
      {% end %}

      @@native_window_map = {} of Void* => EnhancedWindow
      @@native_window_map_lock = Mutex.new

      # The native window handle.
      getter native_window_handle : Void* = Pointer(Void).null

      # :nodoc:
      private def register_native
        h = window
        @native_window_handle = h
        unless h.null?
          @@native_window_map_lock.synchronize { @@native_window_map[h] = self }
        end
      end

      # Test-only factory that builds an `EnhancedWindow` **without**
      # invoking the native webview engine. The resulting instance has a
      # null native handle, so every native-touching method below becomes
      # a no-op (see the `#native_ready?` guards). This lets specs create
      # and wire windows without a display — see
      # `CrystKit::Test::FakeWindowBackend`.
      def self.fake(debug : Bool, title : String, label : String? = nil) : self
        wv = allocate
        wv.fake_initialize(debug, title, label)
        wv
      end

      # :nodoc:
      def fake_initialize(@debug : Bool, title : String, @label = nil)
        @native_window_handle = Pointer(Void).null
        @title = title
        @visible = true
        @window_width = 800
        @window_height = 600
      end

      # :nodoc:
      private def native_ready? : Bool
        !@w.null?
      end

      # :nodoc:
      def init(js : String) : Nil
        return unless native_ready?
        super
      end

      # :nodoc:
      def navigate(url : String) : Nil
        return unless native_ready?
        super
      end

      # :nodoc:
      def html=(html : String) : Nil
        return unless native_ready?
        super
      end

      # :nodoc:
      def bind(name : String, fn : ::Webview::JSProc) : Nil
        return unless native_ready?
        super
      end

      # :nodoc:
      def dispatch(&block : ->) : Nil
        return block.call unless native_ready?
        boxed = Box.box(block)
        @@dispatchs_lock.synchronize { @@dispatchs[block] = boxed }
        check_error(::Webview::LibWebView.dispatch(@w, ->(_w, data) {
          cb = Box(typeof(block)).unbox(data)
          cb.call
          @@dispatchs_lock.synchronize { @@dispatchs.delete(cb) }
        }, boxed))
      end

      # :nodoc:
      def window : Void*
        return Pointer(Void).null unless native_ready?
        super
      end

      # Look up the `EnhancedWindow` registered for *native*, or `nil`
      # if no live window corresponds to that handle.
      def self.lookup(native : Void*) : EnhancedWindow?
        @@native_window_map_lock.synchronize { @@native_window_map[native]? }
      end

      # Optional label for identifying this window.
      property label : String?

      # Last title set on this window.
      getter title : String = ""

      # Set the window title.
      def title=(value : String) : Nil
        @title = value
        super unless @w.null?
      end

      # Returns whether the window is currently hidden (inverse of `visible?`).
      def hidden? : Bool
        !@visible
      end

      # Parent window for child window relationships
      property parent : EnhancedWindow?

      # Whether this window is modal — blocks interaction with its parent
      getter? modal : Bool = false

      # Toggle modal state. Only effective when this window has a parent.
      def modal=(value : Bool) : Nil
        @modal = value
        return unless parent = @parent
        with_native_window do |native_self|
          native_parent = parent.window
          next if native_parent.null?
          ::NativeDesktop::Window.attach(native_self).set_modal(native_parent, value)
        end
      end

      # Whether this window is currently visible.
      getter? visible : Bool = true

      # Whether this window is always on top.
      getter? always_on_top : Bool = false

      # Whether this window is in fullscreen mode.
      getter? fullscreen : Bool = false

      # Whether this window is minimized.
      getter? minimized : Bool = false

      # Whether this window is maximized.
      getter? maximized : Bool = false

      # Tracked window dimensions for cursor positioning.
      @window_width : Int32 = 800
      @window_height : Int32 = 600

      # Size the window.
      def size(width : Int32, height : Int32, hint : ::Webview::SizeHints = ::Webview::SizeHints::NONE) : Nil
        @window_width = width
        @window_height = height
        super unless @w.null?
      end

      # Whether closing this window hides to tray instead of quitting.
      getter? minimize_to_tray : Bool = false

      # Handler called when the window should minimize to tray.
      @on_minimize_to_tray : (-> Nil)?

      # Enable or disable minimize-to-tray behavior. When enabled, closing
      # the window hides it instead of destroying it.
      def minimize_to_tray=(value : Bool) : Nil
        @minimize_to_tray = value
        with_native_window do |native|
          if value
            Platform::Current::EnhancedWindow.enable_close_to_hide(native)
          else
            Platform::Current::EnhancedWindow.disable_close_to_hide(native)
          end
        end
      end

      # Register a callback for when the window should minimize to tray.
      def on_minimize_to_tray(&block : -> Nil) : Nil
        @on_minimize_to_tray = block
      end

      # Handler registered via `#on_close`. Returns true to allow close,
      # false to prevent.
      @on_close_handler : (-> Bool)?

      @close_prevention_installed : Bool = false

      # Register a callback invoked when the OS requests this window to
      # close. The block should return true to allow close, or false to
      # prevent it. Disables minimize-to-tray (the two are mutually
      # exclusive).
      def on_close(&block : -> Bool) : Nil
        @minimize_to_tray = false if @minimize_to_tray
        @on_close_handler = block
        install_close_prevention
      end

      # Returns true to allow the window to close, false to prevent it.
      # Defaults to true when no handler is registered via `#on_close`.
      def handle_close_request : Bool
        handler = @on_close_handler
        if handler
          handler.call
        else
          true
        end
      end

      # :nodoc:
      private def install_close_prevention
        return if @close_prevention_installed
        @close_prevention_installed = true
        native = @native_window_handle
        return if native.null?
        # Disable close-to-hide first — on GTK the close-to-hide signal handler
        # returns TRUE (prevent) and would block the close-prevention handler.
        Platform::Current::EnhancedWindow.disable_close_to_hide(native)
        {% if flag?(:darwin) %}
          Platform::MacOS::EnhancedWindow.enable_close_prevention(native)
        {% elsif flag?(:linux) %}
          Platform::Linux::EnhancedWindow.enable_close_prevention(native)
        {% elsif flag?(:windows) %}
          Platform::Windows::EnhancedWindow.enable_close_prevention(native)
        {% end %}
      end

      # Whether this window has no OS title bar / frame (frameless mode).
      getter? frameless : Bool = false

      # Whether the window background is transparent.
      getter? transparent : Bool = false

      # Window opacity in the range 0.0 (fully transparent) … 1.0 (fully opaque).
      getter opacity : Float64 = 1.0

      # Called when the window gains focus.
      @on_focus_handler : (-> Nil)?
      # Called when the window loses focus.
      @on_blur_handler : (-> Nil)?
      # Called when the window is moved; receives (x, y) in screen coordinates.
      @on_move_handler : ((Int32, Int32) -> Nil)?
      # Called when the window is resized; receives (width, height).
      @on_resize_handler : ((Int32, Int32) -> Nil)?
      # Called when the window is minimized.
      @on_minimize_handler : (-> Nil)?
      # Called when the window is maximized.
      @on_maximize_handler : (-> Nil)?
      # Called when the window is restored from minimized/maximized state.
      @on_restore_handler : (-> Nil)?

      # Child windows owned by this window.
      @children = [] of EnhancedWindow
      getter? debug : Bool

      # Creates a new enhanced window with the given *title* and optional
      # *label*. *debug* enables inspector/remote-debugging support on
      # platforms that provide it.
      def initialize(@debug : Bool, title : String, @label = nil)
        super(@debug, title)
        register_native
      end

      # Runs the main loop until it is terminated.
      #
      # When a `MessageLoopHook` is registered globally, it is used
      # instead of the default run loop. After this method returns, the
      # webview must be `#destroy`ed.
      def run : Nil
        return unless native_ready?
        handler = MessageLoopHook.get
        if handler
          handler.call(@w)
        else
          super
        end
      end

      # Bring this window to the foreground.
      def focus : Nil
        with_native_window do |native|
          ::NativeDesktop::Window.attach(native).focus
          Platform::Current::EnhancedWindow.after_focus(native)
        end
      end

      # Whether this window is currently focused.
      def focused? : Bool
        @focused
      end

      # Show the window if it is hidden.
      def show : Nil
        return if @visible
        @visible = true
        with_native_window { |native| ::NativeDesktop::Window.attach(native).show }
      end

      # Hide the window without destroying it.
      def hide : Nil
        return unless @visible
        @visible = false
        with_native_window { |native| ::NativeDesktop::Window.attach(native).hide }
      end

      # Hide the window immediately rather than via UI-thread dispatch.
      # Used at startup to avoid a visible flash before the run loop
      # processes.
      def hide_now : Nil
        return unless @visible
        @visible = false
        native = window
        return if native.null?
        ::NativeDesktop::Window.attach(native).hide
      end

      # Returns whether the window is currently visible.
      def visible? : Bool
        @visible
      end

      # Show the window at the current mouse cursor position.
      # On macOS the panel is positioned centered on the cursor, slightly above it.
      # On other platforms this is equivalent to `show` + `focus`.
      def show_at_cursor : Nil
        {% if flag?(:darwin) %}
          x, y = cursor_screen_position
          move(x, y)
        {% end %}
        show
        focus
      end

      # :nodoc:
      {% if flag?(:darwin) %}
        private def cursor_screen_position : {Int32, Int32}
          Platform::MacOS::ObjCRuntime.with_autorelease_pool do
            point = Platform::MacOS::ObjCRuntime.msg_point(
              Platform::MacOS::ObjCRuntime.get_class("NSEvent"),
              "mouseLocation",
            )
            cx = point.x.to_i32 - @window_width // 2
            cy = point.y.to_i32 - @window_height * 2 // 3
            {cx, cy}
          end
        end
      {% end %}

      # Set whether this window should always appear on top of other windows.
      def always_on_top=(value : Bool) : Nil
        @always_on_top = value
        with_native_window { |native| ::NativeDesktop::Window.attach(native).always_on_top = value }
      end

      # Returns whether this window is set to always-on-top.
      def always_on_top? : Bool
        @always_on_top
      end

      # Enable or disable frameless (borderless) mode: hides the OS
      # title bar and window frame.
      def frameless=(value : Bool) : Nil
        @frameless = value
        with_native_window { |native| ::NativeDesktop::Window.attach(native).frameless = value }
      end

      # Returns whether this window is in frameless mode.
      def frameless? : Bool
        @frameless
      end

      # Enable or disable a transparent window background, so the
      # desktop can show through.
      def transparent=(value : Bool) : Nil
        @transparent = value
        with_native_window do |native|
          ::NativeDesktop::Window.attach(native).transparent = value
          Platform::Current::EnhancedWindow.set_webview_background(native, value)
        end
      end

      # Set the window opacity (0.0 = fully transparent, 1.0 = fully opaque).
      # Raises ArgumentError when the value is outside [0.0, 1.0].
      def opacity=(value : Float64) : Nil
        raise ArgumentError.new("Opacity must be between 0.0 and 1.0, got #{value}") unless value >= 0.0 && value <= 1.0
        @opacity = value
        with_native_window { |native| ::NativeDesktop::Window.attach(native).opacity = value }
      end

      # Returns the current window opacity.
      def opacity : Float64
        @opacity
      end

      # Register a callback invoked when this window gains focus.
      def on_focus(&handler : -> Nil) : Nil
        @on_focus_handler = handler
      end

      # Register a callback invoked when this window loses focus.
      def on_blur(&handler : -> Nil) : Nil
        @on_blur_handler = handler
      end

      # Register a callback invoked when this window is moved.
      # The block receives the new (x, y) screen coordinates.
      def on_move(&handler : (Int32, Int32) -> Nil) : Nil
        @on_move_handler = handler
      end

      # Register a callback invoked when this window is resized.
      # The block receives the new (width, height).
      def on_resize(&handler : (Int32, Int32) -> Nil) : Nil
        @on_resize_handler = handler
      end

      # Register a callback invoked when this window is minimized.
      def on_minimize(&handler : -> Nil) : Nil
        @on_minimize_handler = handler
      end

      # Register a callback invoked when this window is maximized.
      def on_maximize(&handler : -> Nil) : Nil
        @on_maximize_handler = handler
      end

      # Register a callback invoked when this window is restored.
      def on_restore(&handler : -> Nil) : Nil
        @on_restore_handler = handler
      end

      # Emit a focus event.
      def emit_focus : Nil
        @focused = true
        @on_focus_handler.try(&.call)
      end

      # Emit a blur event.
      def emit_blur : Nil
        @focused = false
        @on_blur_handler.try(&.call)
      end

      # Emit a move event with the new position.
      def emit_move(x : Int32, y : Int32) : Nil
        @tracked_x = x
        @tracked_y = y
        @on_move_handler.try(&.call(x, y))
      end

      # Emit a resize event with the new dimensions.
      def emit_resize(width : Int32, height : Int32) : Nil
        @on_resize_handler.try(&.call(width, height))
      end

      # Emit a minimize event.
      def emit_minimize : Nil
        @on_minimize_handler.try(&.call)
      end

      # Emit a maximize event.
      def emit_maximize : Nil
        @on_maximize_handler.try(&.call)
      end

      # Emit a restore event.
      def emit_restore : Nil
        @on_restore_handler.try(&.call)
      end

      # Move the window to screen coordinates (x, y).
      def move(x : Int32, y : Int32) : Nil
        @tracked_x = x
        @tracked_y = y
        dispatch do
          native = window
          next if native.null?
          ::NativeDesktop::Window.attach(native).move(x, y)
        end
      end

      # Last position this window was moved to via `#move` / `#move_by`.
      @tracked_x : Int32 = 0
      @tracked_y : Int32 = 0

      getter tracked_x : Int32
      getter tracked_y : Int32

      # Move the window by a relative (dx, dy) delta from its last
      # tracked position. For accurate results, `#move` must have been
      # called first to seed the tracked origin.
      def move_by(dx : Int32, dy : Int32) : Nil
        move(@tracked_x + dx, @tracked_y + dy)
      end

      # Minimize the window.
      def minimize : Nil
        @minimized = true
        @maximized = false
        with_native_window { |native| ::NativeDesktop::Window.attach(native).minimize }
        emit_minimize
      end

      # Maximize the window.
      def maximize : Nil
        @maximized = true
        @minimized = false
        with_native_window { |native| ::NativeDesktop::Window.attach(native).maximize }
        emit_maximize
      end

      # Restore the window from minimized or maximized state.
      def restore : Nil
        @minimized = false
        @maximized = false
        with_native_window { |native| ::NativeDesktop::Window.attach(native).restore }
        emit_restore
      end

      # Returns the window position in screen coordinates. The native
      # window may already be gone by the time the run loop exits (for
      # example when the user closes the last window), so ask the webview
      # for its current handle instead of trusting the cached
      # `@native_window_handle`, which would then be dangling.
      def position : {Int32, Int32}
        return {0, 0} if @native_window_handle.null?
        h = window
        return {0, 0} if h.null?
        ::NativeDesktop::Window.attach(h).position
      end

      # Whether the underlying native window is still open. The cached
      # handle remains non-null after the OS closes the window, so check
      # the webview's current handle as well.
      # :nodoc:
      def native_window_open? : Bool
        return false if @native_window_handle.null?
        !window.null?
      end

      # Toggle fullscreen mode on or off.
      def fullscreen=(value : Bool) : Nil
        @fullscreen = value
        with_native_window { |native| ::NativeDesktop::Window.attach(native).fullscreen = value }
      end

      # Create a child window parented to this window. Returns the new
      # child.
      def create_child(options : WindowOptions) : EnhancedWindow
        child = native_ready? ? EnhancedWindow.new(options.debug?, options.title, options.label) : EnhancedWindow.fake(options.debug?, options.title, options.label)
        child.size(options.width, options.height, options.hint)
        child.title = options.title
        child.parent = self
        child.modal = options.modal?
        child.always_on_top = options.always_on_top? if options.always_on_top?
        child.frameless = options.frameless? if options.frameless?
        child.transparent = options.transparent? if options.transparent?
        child.opacity = options.opacity unless options.opacity == 1.0
        child.minimize_to_tray = options.minimize_to_tray?
        child.fullscreen = options.fullscreen? if options.fullscreen?
        if url = options.url
          child.navigate(url)
        end
        @children << child
        child
      end

      # Returns all direct child windows of this window.
      def children : Array(EnhancedWindow)
        @children.dup
      end

      # Returns true if this window has a parent (i.e., is a child window).
      def child? : Bool
        !@parent.nil?
      end

      # Remove *child* from this window's children.
      def remove_child(child : EnhancedWindow) : Nil
        @children.delete(child)
      end

      # Destroy this window and all its children. Idempotent:
      # subsequent calls are no-ops.
      def destroy : Nil
        return if @native_window_handle.null?
        # Mark the window as dead BEFORE freeing the underlying C++
        # `webview` object.  Spawned fibers from `bind_async` may call
        # `#respond` at any time; without this guard they would invoke
        # `webview_return` on a dangling `@w` and segfault (signal 11
        # in `engine_base::resolve` / `::dispatch`).
        mark_dead!
        # Drop any in-flight async seq ids registered against this
        # window so a fiber that completes after destruction cannot
        # `webview_return` into the freed C++ `webview`.
        @@pending_async_lock.synchronize { @@pending_async.reject! { |_, w| w.same?(self) } }
        # Fail any in-flight Core::MainThread.dispatch_sync requests so
        # fibers parked waiting for main wake with WINDOW_DESTROYED
        # instead of hanging on a freed webview.
        ::CrystKit::Core::MainThread.fail_all_pending(
          "Primary window destroyed while dispatch_sync was in flight",
          "WINDOW_DESTROYED",
        )
        @@native_window_map_lock.synchronize { @@native_window_map.delete(@native_window_handle) }
        h = @native_window_handle
        @native_window_handle = Pointer(Void).null

        children = @children.dup
        children.each do |child|
          begin
            child.destroy
          rescue ex
            Log.warn(exception: ex) { "Failed to destroy child window" }
          end
        end
        @children.clear

        @parent.try(&.remove_child(self))

        {% if flag?(:win32) %}
          Platform::Current::EnhancedWindow.disable_close_to_hide(h)
          Platform::Windows::EnhancedWindow.disable_close_prevention(h)
          # Destroy the HWNDs synchronously so Chromium can
          # unregister Chrome_WidgetWin_0 on exit. Skip the C++
          # destructor (super) because releasing WebView2 COM
          # objects sends window messages into a dying engine.
          Platform::Windows::LibUser32.DestroyWindow(h)
        {% else %}
          Platform::Current::EnhancedWindow.disable_close_to_hide(h)
          super
        {% end %}
        @async_bindings_lock.synchronize { @async_bindings.clear }
      end

      # :nodoc:
      private def with_native_window(&block : Void* ->)
        dispatch do
          native = window
          next if native.null?
          block.call(native)
        end
      end

      @focused : Bool = false

      # :nodoc:
      private def setup_lifecycle_hooks
        super

        # Track focus/blur state via JavaScript events
        init(<<-JS)
        if (typeof window.__enhanced_window_setup === 'undefined') {
          window.__enhanced_window_setup = true;
          window.addEventListener('focus', () => {
            if (typeof window.__crystal_window_focused !== 'undefined') {
              window.__crystal_window_focused();
            }
          });
          window.addEventListener('blur', () => {
            if (typeof window.__crystal_window_blurred !== 'undefined') {
              window.__crystal_window_blurred();
            }
          });
        }
      JS

        bind("__crystal_window_focused", JSProc.new { |_|
          emit_focus
          JSON::Any.new(nil)
        })

        bind("__crystal_window_blurred", JSProc.new { |_|
          emit_blur
          JSON::Any.new(nil)
        })
      end

      #
      # The upstream `::Webview::Webview#bind` calls the handler and
      # `webview_return` synchronously inside the C callback frame, which
      # blocks the UI thread for the handler's duration.  The C API
      # (`webview_bind` + `webview_return`) is inherently asynchronous —
      # the `seq` token decouples request arrival from response delivery.
      #
      # `bind_async` exposes that capability: the block receives the `seq`
      # string and the parsed JSON args, returns immediately, and is
      # expected to call `#respond` later (from any thread/fiber) with the
      # same `seq`.  This keeps the webview's UI thread free.

      # Stores async bind callback boxes keyed by binding name so the GC
      # doesn't collect them and `#unbind_async` can clean up.
      @async_bindings = {} of String => Pointer(Void)
      @async_bindings_lock = Mutex.new

      # Maps an in-flight async request's `seq` (as generated by the
      # webview's JS RPC layer and received in the `bind_async` C
      # callback) to the `EnhancedWindow` on which `bind_async` was
      # called.  `#respond` looks up the destination window by `seq`
      # here, so the response is always delivered to the window that
      # owns the request — never to whatever `self` the caller happens
      # to be bound to.
      #
      # Entries are one-shot: `#respond` consumes the seq.  `#destroy`
      # purges any entries still pointing at the dying window so a
      # late fiber cannot `webview_return` into a freed C++ `webview`.
      @@pending_async = {} of String => EnhancedWindow
      @@pending_async_lock = Mutex.new

      # Binds a native callback whose response is delivered asynchronously
      # via `#respond`.  The block receives the request sequence id (as a
      # Crystal `String`, safe to retain) and the parsed JSON arguments.
      # The block **must not** call `#respond` synchronously — it should
      # spawn a fiber and return immediately so the UI thread is not
      # blocked.
      #
      # The sequence id is generated by the webview's internal JS RPC
      # layer (`crypto.getRandomValues` → 128-bit hex string) — the
      # framework never creates or tracks it.  It simply echoes the `seq`
      # received from the C callback back to `webview_return`.
      #
      # ```
      # wv.bind_async("db.query") do |seq, args|
      #   spawn do
      #     result = DB.query(args[0].as_s)
      #     wv.respond(seq, 0, result.to_json)
      #   end
      # end
      # ```
      private record AsyncBindContext, host : EnhancedWindow, cb : String, Array(JSON::Any) -> Nil

      def bind_async(name : String, &block : String, Array(JSON::Any) -> Nil)
        return unless native_ready?
        w = @w
        ctx = AsyncBindContext.new(self, block)
        boxed = Box.box(ctx)
        @async_bindings_lock.synchronize { @async_bindings[name] = boxed }

        ::Webview::LibWebView.bind(w, name, ->(id : LibC::Char*, req : LibC::Char*, data : Void*) {
          seq = String.new(id)
          raw = JSON.parse(String.new(req)).as_a
          c = Box(AsyncBindContext).unbox(data)
          # Record the owning window for this seq so the eventual
          # `#respond` routes the response back to THIS window, not to
          # whatever `self` the caller happens to be bound to.
          @@pending_async_lock.synchronize { @@pending_async[seq] = c.host }
          c.cb.call(seq, raw)
        }, boxed)
      end

      # Removes an async binding previously created by `#bind_async`.
      def unbind_async(name : String) : Nil
        ::Webview::LibWebView.unbind(@w, name)
        @async_bindings_lock.synchronize { @async_bindings.delete(name) }
      end

      # Delivers a deferred response to a `bind_async` call.  Safe to call
      # from any thread — the webview C library dispatches internally.
      #
      # *seq* is the opaque token received in the `bind_async` block —
      # generated by the webview's JS RPC layer, not by the framework.
      #
      # *status*: `0` = success (result is a valid JSON value),
      #           `1` = error (result is a JSON error object).
      #
      # *result_json* is a JSON string (e.g. an `IPC::ResponseEnvelope`
      # serialized via `#to_json`).  It is passed directly to
      # `webview_return` — the webview's JS `onReply` calls `JSON.parse` on
      # it, producing a JS object, and the CrystKit JS bridge's
      # `handleEnvelope` accepts both strings and objects.
      #
      # The response is routed to the window whose `bind_async` registered
      # *seq* — looked up here, not via `self` — and dropped if that
      # window has since been destroyed (so we never dereference a freed
      # C++ `webview`).
      def respond(seq : String, status : Int32, result_json : String) : ::Webview::LibWebView::Error
        window = @@pending_async_lock.synchronize do
          @@pending_async.delete(seq)
        end
        return ::Webview::LibWebView::Error::NOT_FOUND unless window

        @@native_window_map_lock.synchronize do
          unless window.ipc_alive? && @@native_window_map[window.native_window_handle]?.same?(window)
            next ::Webview::LibWebView::Error::INVALID_STATE
          end
          ::Webview::LibWebView.webview_return(window.webview_handle, seq, status, result_json)
        end
      end

      # :nodoc:
      protected def webview_handle : ::Webview::LibWebView::T
        @w
      end
    end
  end
end
