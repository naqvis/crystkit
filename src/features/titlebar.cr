require "log"
require "native_desktop"

module CrystKit::Features
  # :nodoc:
  abstract class TitlebarProvider
    abstract def apply(window_ptr : Void*, config : TitlebarConfig) : Nil
  end

  # :nodoc:
  class NativeTitlebarProvider < TitlebarProvider
    def apply(window_ptr : Void*, config : TitlebarConfig) : Nil
      ::NativeDesktop::Window.attach(window_ptr).titlebar_overlay = config.overlay?
    end
  end

  # Configuration describing how a window's title bar looks and behaves.
  #
  # Most properties are macOS-specific (overlay, height, separator,
  # traffic-light padding); on Linux and Windows only *overlay* is
  # consulted, where it strips native decorations to produce a frameless
  # window.
  #
  # Usage:
  # ```
  # wv.titlebar do |t|
  #   t.overlay = true
  #   t.height = 38
  #   t.separator = false
  # end
  # ```
  class TitlebarConfig
    # Whether the web content should extend behind the title bar.
    property? overlay : Bool = false
    # Custom title bar height in logical pixels (macOS only).
    # `0` leaves the system default untouched.
    property height : Int32 = 0
    # Whether to draw the separator line between the title bar and
    # content (macOS only).
    property? separator : Bool = true
    # `{x, y}` padding applied to the traffic-light buttons (macOS only).
    # Defaults to `{12, 8}`.
    property traffic_light_padding : {Int32, Int32} = {12, 8}

    # Creates a configuration.
    def initialize(
      @overlay = false,
      @height = 0,
      @separator = true,
      @traffic_light_padding : {Int32, Int32} = {12, 8},
    )
    end
  end

  # Applies a `TitlebarConfig` to a native window handle.
  class Titlebar
    Log = ::Log.for(self)

    getter config : TitlebarConfig

    # Creates a titlebar applier bound to *config*.
    def initialize(@config = TitlebarConfig.new,
                   @provider : TitlebarProvider = NativeTitlebarProvider.new)
    end

    # Applies the configuration to the native window *window_ptr*.
    #
    # A null pointer is silently ignored.
    def apply(window_ptr : Void*) : Nil
      return if window_ptr.null?

      @provider.apply(window_ptr, config)
    end
  end
end
