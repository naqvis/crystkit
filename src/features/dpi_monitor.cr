require "native_desktop"

module CrystKit::Features
  # Reports the primary display's scale factor and geometry.
  class DPIMonitor
    struct DisplayInfo
      getter name : String
      getter scale_factor : Float64
      getter width : Int32
      getter height : Int32

      def initialize(@name : String, @scale_factor : Float64, @width : Int32, @height : Int32)
      end
    end

    # :nodoc:
    abstract class Provider
      abstract def current_display : DisplayInfo
    end

    # :nodoc:
    class NativeProvider < Provider
      def current_display : DisplayInfo
        display = ::NativeDesktop.displays.primary
        return DisplayInfo.new("Display", 1.0, 1920, 1080) unless display
        DisplayInfo.new(display.name, display.scale_factor, display.bounds.width, display.bounds.height)
      end
    end

    def initialize(@provider : Provider = NativeProvider.new)
    end

    # Returns the primary display's scale factor.
    def current_scale_factor : Float64
      @provider.current_display.scale_factor
    end

    # Returns a snapshot of the primary display.
    def current_display : DisplayInfo
      @provider.current_display
    end
  end
end
