require "log"
require "native_desktop"
require "../core/errors"
require "../core/fibers"

module CrystKit
  module Features
    # :nodoc:
    abstract class PositioningProvider
      abstract def screen_list : Array(ScreenInfo)
      abstract def cursor_position : Point
      abstract def start_screen_monitor(callback : ->) : Nil
    end

    # :nodoc:
    class NativePositioningProvider < PositioningProvider
      def screen_list : Array(ScreenInfo)
        ::NativeDesktop.displays.all.map_with_index do |display, index|
          ScreenInfo.new(rectangle(display.bounds), rectangle(display.work_area), index)
        end
      end

      def cursor_position : Point
        point = ::NativeDesktop.displays.cursor
        Point.new(point.x, point.y)
      end

      def start_screen_monitor(callback : ->) : Nil
        ::CrystKit::Core::Fibers.spawn(name: "display-monitor") do
          previous = screen_list
          loop do
            sleep 2.seconds
            current = screen_list
            unless current == previous
              previous = current
              callback.call
            end
          rescue ::NativeDesktop::RuntimeError
            break
          end
        end
      end

      private def rectangle(value : ::NativeDesktop::Rectangle) : Rectangle
        Rectangle.new(value.x, value.y, value.width, value.height)
      end
    end

    # Snap directions for window to screen edges.
    enum SnapDirection
      Left
      Right
      Top
      Bottom
      TopLeft
      TopRight
      BottomLeft
      BottomRight
    end

    # Tile layout styles for arranging multiple windows on a display.
    enum TileLayout
      Grid
      Horizontal
      Vertical
    end

    # Screen corner positions for window placement.
    enum Corner
      TopLeft
      TopRight
      BottomLeft
      BottomRight
    end

    # Screen edge positions for window placement.
    enum Edge
      Top
      Bottom
      Left
      Right
      Center
    end

    # A 2-D point used for offsets and positions.
    struct Point
      property x : Int32
      property y : Int32

      # Create a point at coordinates (*x*, *y*), defaulting to the origin.
      def initialize(@x = 0, @y = 0)
      end

      # Vector addition: returns a new `Point` whose coordinates are the
      # component-wise sum of `self` and *other*.
      def +(other : Point) : Point
        Point.new(@x + other.x, @y + other.y)
      end

      # Append a `"(x, y)"` representation of this point to *io*.
      def to_s(io : IO)
        io << "(#{@x}, #{@y})"
      end
    end

    # An axis-aligned rectangle.
    struct Rectangle
      property x : Int32
      property y : Int32
      property width : Int32
      property height : Int32

      # Create a rectangle with origin (*x*, *y*) and the given dimensions.
      def initialize(@x = 0, @y = 0, @width = 0, @height = 0)
      end

      # Return the x coordinate of the right edge (`x + width`).
      def right : Int32
        @x + @width
      end

      # Return the y coordinate of the bottom edge (`y + height`).
      def bottom : Int32
        @y + @height
      end

      # Return the geometric centre of the rectangle, rounded toward zero.
      def center : Point
        Point.new(@x + @width // 2, @y + @height // 2)
      end

      # Append a `"Rectangle(x, y, WxH)"` representation of this rectangle to *io*.
      def to_s(io : IO)
        io << "Rectangle(#{@x}, #{@y}, #{@width}x#{@height})"
      end
    end

    # Screen information returned by WindowPositioner#screen_info.
    struct ScreenInfo
      # Full screen bounds (origin + dimensions).
      getter bounds : Rectangle
      # Work area – screen bounds minus taskbar / menu bar / dock.
      getter work_area : Rectangle
      # Display index (0-based).
      getter display : Int32

      # Build a `ScreenInfo` from its raw components.
      def initialize(@bounds : Rectangle, @work_area : Rectangle, @display = 0)
      end
    end

    # Utility class for positioning windows relative to screen corners, edges,
    # the system tray icon, or the cursor.
    #
    # All positioning methods return a `Point` representing the top-left corner
    # that the window should be moved to.  The caller is responsible for actually
    # moving the window (platform-specific).
    class WindowPositioner
      # Default margin kept between a window and the screen edge (pixels).
      DEFAULT_MARGIN = 8

      @screen_change_handler : Proc(Nil)?
      @provider : PositioningProvider?
      @monitor_started = false

      # Construct a positioner bound to *provider*. Display monitoring starts
      # lazily when `#on_screen_change` is used.
      def initialize(@provider : PositioningProvider = NativePositioningProvider.new)
        @screen_change_handler = nil
      end

      # :nodoc:
      private def start_platform_monitor : Nil
        return if @monitor_started
        return unless source = @provider
        @monitor_started = true
        source.start_screen_monitor(-> { notify_screen_change })
      end

      # :nodoc:
      private def provider : PositioningProvider
        @provider ||= NativePositioningProvider.new
      end

      # :nodoc:
      # ── Corner positioning ──────────────────────────────

      # Calculate the position for a window of *window_size* placed at *corner*
      # on the primary display (or the display specified by *display*).
      #
      # The position respects the work area (taskbar / menu bar) and applies
      # *offset* as a fine-tuning adjustment.
      #
      # Raises `Core::Error` if the display index is invalid.
      def position_at_corner(
        window_size : Rectangle,
        corner : Corner,
        offset : Point = Point.new,
        display : Int32? = nil,
      ) : Point
        info = screen_info(display)
        wa = info.work_area

        x, y = case corner
               in Corner::TopLeft
                 {wa.x, wa.y}
               in Corner::TopRight
                 {wa.right - window_size.width, wa.y}
               in Corner::BottomLeft
                 {wa.x, wa.bottom - window_size.height}
               in Corner::BottomRight
                 {wa.right - window_size.width, wa.bottom - window_size.height}
               end

        result = Point.new(x + offset.x, y + offset.y)
        ensure_on_screen(result, window_size, info)
      end

      # ── Edge positioning ────────────────────────────────

      # Calculate the position for a window of *window_size* placed at *edge*
      # on the primary display (or the display specified by *display*).
      #
      # - `Top` / `Bottom`: window is horizontally centred on the edge.
      # - `Left` / `Right`: window is vertically centred on the edge.
      # - `Center`: window is centred on the work area.
      #
      # *offset* is applied after the base position is computed.
      def position_at_edge(
        window_size : Rectangle,
        edge : Edge,
        offset : Point = Point.new,
        display : Int32? = nil,
      ) : Point
        info = screen_info(display)
        wa = info.work_area

        x, y = case edge
               in Edge::Top
                 {wa.x + (wa.width - window_size.width) // 2, wa.y}
               in Edge::Bottom
                 {wa.x + (wa.width - window_size.width) // 2, wa.bottom - window_size.height}
               in Edge::Left
                 {wa.x, wa.y + (wa.height - window_size.height) // 2}
               in Edge::Right
                 {wa.right - window_size.width, wa.y + (wa.height - window_size.height) // 2}
               in Edge::Center
                 {wa.x + (wa.width - window_size.width) // 2,
                  wa.y + (wa.height - window_size.height) // 2}
               end

        result = Point.new(x + offset.x, y + offset.y)
        ensure_on_screen(result, window_size, info)
      end

      # ── Tray-relative positioning ───────────────────────

      # Calculate the position for a window of *window_size* placed adjacent to
      # the system tray icon whose bounding rectangle is *tray_rect*.
      #
      # The window is placed above or below the tray icon depending on which
      # half of the screen the tray occupies, and horizontally aligned with the
      # tray icon centre.  *offset* is applied after the base position is
      # computed.
      #
      # Raises `Core::Error` if *tray_rect* has zero dimensions.
      def position_at_tray(
        window_size : Rectangle,
        tray_rect : Rectangle,
        offset : Point = Point.new,
        display : Int32? = nil,
      ) : Point
        if tray_rect.width <= 0 || tray_rect.height <= 0
          raise Core::Error.new(
            "Tray rectangle must have positive dimensions",
            code: "INVALID_TRAY_RECT"
          )
        end

        info = screen_info(display)
        wa = info.work_area

        # Determine whether the tray is in the bottom or top half of the screen.
        tray_center_y = tray_rect.y + tray_rect.height // 2
        screen_mid_y = wa.y + wa.height // 2

        # Horizontally centre the window on the tray icon.
        x = tray_rect.x + tray_rect.width // 2 - window_size.width // 2

        y = if tray_center_y >= screen_mid_y
              # Tray is in the bottom half → place window above the tray icon.
              tray_rect.y - window_size.height - DEFAULT_MARGIN
            else
              # Tray is in the top half → place window below the tray icon.
              tray_rect.bottom + DEFAULT_MARGIN
            end

        result = Point.new(x + offset.x, y + offset.y)
        ensure_on_screen(result, window_size, info)
      end

      # ── Cursor-relative positioning ─────────────────────

      # Calculate the position for a window of *window_size* placed at the
      # current cursor position.
      #
      # The window is offset so that it does not obscure the cursor tip.
      # *offset* is applied after the base position is computed.
      def position_at_cursor(
        window_size : Rectangle,
        offset : Point = Point.new,
        display : Int32? = nil,
      ) : Point
        cursor = cursor_position
        info = screen_info(display)

        # Place the window slightly below and to the right of the cursor.
        x = cursor.x + DEFAULT_MARGIN
        y = cursor.y + DEFAULT_MARGIN

        result = Point.new(x + offset.x, y + offset.y)
        ensure_on_screen(result, window_size, info)
      end

      # ── On-screen constraint ────────────────────────────

      # Adjust *position* so that a window of *window_size* remains fully within
      # the work area of *info*.
      #
      # If the window is larger than the work area in any dimension it is
      # clamped to the work-area origin in that dimension.
      def ensure_on_screen(
        position : Point,
        window_size : Rectangle,
        info : ScreenInfo? = nil,
      ) : Point
        info ||= screen_info(nil)
        wa = info.work_area

        x = position.x
        y = position.y

        # Clamp right edge.
        if x + window_size.width > wa.right
          x = wa.right - window_size.width
        end

        # Clamp bottom edge.
        if y + window_size.height > wa.bottom
          y = wa.bottom - window_size.height
        end

        # Clamp left edge.
        x = wa.x if x < wa.x

        # Clamp top edge.
        y = wa.y if y < wa.y

        Point.new(x, y)
      end

      # ── Screen information ─────────────────────────────

      # Return screen information for the given display index.
      #
      # When *display* is `nil` the primary display (index 0) is used.
      # Raises `Core::Error` if the display index is out of range.
      def screen_info(display : Int32? = nil) : ScreenInfo
        idx = display || 0
        screens = platform_screen_list

        if idx < 0 || idx >= screens.size
          raise Core::Error.new(
            "Display index #{idx} is out of range (#{screens.size} display(s) available)",
            code: "INVALID_DISPLAY"
          )
        end

        screens[idx]
      end

      # Return the number of connected displays.
      def display_count : Int32
        platform_screen_list.size
      end

      # ── Screen-change notification ──────────────────────

      # Register a callback that is invoked when the screen configuration
      # changes (e.g. a monitor is connected or disconnected, resolution changes).
      def on_screen_change(&handler : ->) : Nil
        @screen_change_handler = handler
        start_platform_monitor
      end

      # Trigger the registered screen-change handler.
      def notify_screen_change : Nil
        if handler = @screen_change_handler
          begin
            handler.call
          rescue ex
            Log.error { "WindowPositioner: screen-change handler raised: #{ex.message}" }
          end
        end
      end

      # ── Snap / Maximize / Tile (P2) ─────────────────────────────────────

      # Snap a window to screen edge. Fills half/quarter of the work area.
      # Requires the caller to dispatch to the UI thread.
      def snap(window : ::CrystKit::Core::EnhancedWindow, direction : SnapDirection,
               display : Int32? = nil) : Nil
        info = screen_info(display)
        wa = info.work_area

        x = wa.x; y = wa.y
        w = wa.width; h = wa.height

        case direction
        in SnapDirection::Left
          w = w // 2
        in SnapDirection::Right
          x += w // 2; w = w // 2
        in SnapDirection::Top
          h = h // 2
        in SnapDirection::Bottom
          y += h // 2; h = h // 2
        in SnapDirection::TopLeft
          w = w // 2; h = h // 2
        in SnapDirection::TopRight
          x += w // 2; w = w // 2; h = h // 2
        in SnapDirection::BottomLeft
          y += h // 2; w = w // 2; h = h // 2
        in SnapDirection::BottomRight
          x += w // 2; y += h // 2; w = w // 2; h = h // 2
        end

        window.dispatch do
          window.move(x, y)
          window.size(w, h, SizeHints::NONE)
        end
      end

      # Maximize window to fill screen work area.
      def maximize(window : ::CrystKit::Core::EnhancedWindow, display : Int32? = nil) : Nil
        info = screen_info(display)
        wa = info.work_area
        window.dispatch do
          window.move(wa.x, wa.y)
          window.size(wa.width, wa.height, SizeHints::NONE)
        end
      end

      # Tile multiple windows across a display using the given layout.
      def tile(windows : Array(::CrystKit::Core::EnhancedWindow), layout : TileLayout,
               display : Int32? = nil) : Nil
        return if windows.empty?
        info = screen_info(display)
        wa = info.work_area
        n = windows.size

        case layout
        in TileLayout::Horizontal
          seg_w = wa.width // n
          windows.each_with_index do |window_view, index|
            window_view.dispatch do
              window_view.move(wa.x + index * seg_w, wa.y)
              window_view.size(seg_w, wa.height, SizeHints::NONE)
            end
          end
        in TileLayout::Vertical
          seg_h = wa.height // n
          windows.each_with_index do |window_view, index|
            window_view.dispatch do
              window_view.move(wa.x, wa.y + index * seg_h)
              window_view.size(wa.width, seg_h, SizeHints::NONE)
            end
          end
        in TileLayout::Grid
          cols = Math.sqrt(n.to_f).ceil.to_i
          rows = (n.to_f / cols).ceil.to_i
          cell_w = wa.width // cols
          cell_h = wa.height // rows
          windows.each_with_index do |window_view, index|
            col = index % cols
            row = index // cols
            window_view.dispatch do
              window_view.move(wa.x + col * cell_w, wa.y + row * cell_h)
              window_view.size(cell_w, cell_h, SizeHints::NONE)
            end
          end
        end
      end

      # ── Platform hooks (overridable for testing) ───────────────────────────

      # Return a list of ScreenInfo structs, one per connected display.
      # Index 0 is the primary display.
      protected def platform_screen_list : Array(ScreenInfo)
        provider.screen_list
      end

      # Return the current cursor position in screen coordinates.
      def cursor : Point
        cursor_position
      end

      # Return the current cursor position in screen coordinates.
      protected def cursor_position : Point
        provider.cursor_position
      end
    end
  end
end
