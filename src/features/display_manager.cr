require "log"
require "../security/capability"
require "./positioning"
require "./dpi_monitor"
require "native_desktop"

module CrystKit
  module Features
    # Describes a single physical display attached to the system.
    #
    # An immutable snapshot of a display's identity, geometry, scaling, and
    # refresh characteristics at the moment it was produced. To react to
    # display attach/detach/resolution events, register a callback via
    # `DisplayManager#on_display_change`.
    #
    # *bounds* covers the entire display surface in logical pixels, while
    # *work_area* excludes OS chrome such as the taskbar, dock, or menu bar.
    # *scale_factor* is the display's DPI multiplier (`1.0` being 100%).
    struct Monitor
      # Zero-based display index; the primary display is `0`.
      #
      # Secondary displays follow in platform-defined order. The index is only
      # meaningful within the `DisplayManager` snapshot that produced it.
      getter id : Int32

      # Human-readable display name, or a fallback when the OS does not supply one.
      getter name : String

      # Full screen geometry (origin and dimensions) in logical pixels.
      getter bounds : Rectangle

      # Usable work area in logical pixels, excluding taskbar / dock / menu bar.
      getter work_area : Rectangle

      # Display DPI scale factor, where `1.0` is 100% (e.g. `2.0` is Retina).
      getter scale_factor : Float64

      # `true` when this is the system's primary display.
      getter? is_primary : Bool

      # Nominal refresh rate in hertz. Defaults to `60` when the platform does
      # not report a value.
      getter refresh_rate : Int32

      # Creates a monitor snapshot from raw display metadata.
      #
      # *scale_factor*, *is_primary*, and *refresh_rate* default to `1.0`,
      # `false`, and `60` respectively. Application code should obtain `Monitor`
      # instances via `DisplayManager#monitors` or `#primary_monitor`.
      def initialize(@id : Int32, @name : String, @bounds : Rectangle,
                     @work_area : Rectangle, @scale_factor = 1.0,
                     @is_primary = false, @refresh_rate = 60)
      end
    end

    # Enumerates attached displays and reports display configuration changes.
    #
    # Each call to `#monitors` performs a fresh query; callers that need a
    # consistent view across multiple reads should cache the result for the
    # duration of their operation.
    #
    # ```
    # dm = CrystKit::Features::DisplayManager.new
    # dm.monitors.each do |monitor|
    #   puts "#{monitor.name}: #{monitor.bounds.width}x#{monitor.bounds.height}"
    # end
    # dm.on_display_change { puts "Display configuration changed" }
    # ```
    class DisplayManager
      Log = ::Log.for(self)
      @positioner : WindowPositioner

      # :nodoc:
      abstract class Provider
        abstract def all : Array(::NativeDesktop::Display)
      end

      # :nodoc:
      class NativeProvider < Provider
        def all : Array(::NativeDesktop::Display)
          ::NativeDesktop.displays.all
        end
      end

      # Creates a display manager. Callbacks registered via `#on_display_change`
      # fire even if `#monitors` has never been called.
      def initialize(@provider : Provider = NativeProvider.new)
        @positioner = WindowPositioner.new
      end

      # Returns snapshots of every connected display, ordered by display index.
      #
      # The primary display is always at index `0`. Mutating the returned array
      # has no effect on the manager's state.
      def monitors : Array(Monitor)
        @provider.all.map_with_index do |display, i|
          Monitor.new(
            id: i,
            name: display.name,
            bounds: rectangle(display.bounds),
            work_area: rectangle(display.work_area),
            scale_factor: display.scale_factor,
            is_primary: display.primary?,
            refresh_rate: 60
          )
        end
      end

      # Returns the primary display (index `0`).
      #
      # Raises when no displays are reported by the platform.
      def primary_monitor : Monitor
        monitors.first
      end

      # Returns the display at *index*, or `nil` when the index is out of range.
      #
      # Negative indices always return `nil`. Shares `#monitors` snapshot
      # semantics — call it once and reuse the result if you need consistent
      # data across accesses.
      def monitor_at(index : Int32) : Monitor?
        all = monitors
        all[index]? if index >= 0 && index < all.size
      end

      # Returns the number of connected displays.
      #
      # Cheaper than `#monitors.size`.
      def monitor_count : Int32
        @provider.all.size
      end

      # Registers a callback invoked when the display configuration changes
      # (e.g. monitor hot-plug, resolution change, DPI change).
      #
      # The handler receives no arguments and returns `Nil`. Only one handler
      # may be registered at a time — a subsequent call replaces the previous
      # handler. The callback runs on the platform monitor's fiber, so
      # long-running work should be dispatched to another fiber.
      def on_display_change(&handler : -> Nil) : Nil
        @positioner.on_screen_change(&handler)
      end

      private def rectangle(value : ::NativeDesktop::Rectangle) : Rectangle
        Rectangle.new(value.x, value.y, value.width, value.height)
      end
    end
  end
end
