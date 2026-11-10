require "log"
require "native_desktop"

module CrystKit::Features
  # Drives one application window into and out of kiosk-style presentation.
  # This is a presentation control, not an operating-system security boundary.
  class KioskMode
    Log = ::Log.for(self)

    # :nodoc:
    abstract class Provider
      abstract def attach(window : Void*) : Nil
      abstract def enter : Nil
      abstract def exit : Nil
      abstract def active? : Bool
      abstract def cleanup : Nil
    end

    # :nodoc:
    class NativeProvider < Provider
      @kiosk : ::NativeDesktop::Kiosk?

      def attach(window : Void*) : Nil
        @kiosk.try(&.cleanup)
        @kiosk = ::NativeDesktop::Kiosk.new(window)
      end

      def enter : Nil
        @kiosk.try(&.enter)
      end

      def exit : Nil
        @kiosk.try(&.exit)
      end

      def active? : Bool
        @kiosk.try(&.active?) || false
      end

      def cleanup : Nil
        @kiosk.try(&.cleanup)
        @kiosk = nil
      end
    end

    getter? installed : Bool = false

    def initialize(@provider : Provider = NativeProvider.new)
    end

    # Binds the controller to a native window.
    def install(native_window : Void*) : Nil
      return if native_window.null?
      @installed = safely { @provider.attach(native_window) }
    end

    # Enters kiosk presentation. Passing a handle also installs that window.
    def enter(native_window : Void* = Pointer(Void).null) : Nil
      install(native_window) unless native_window.null?
      return unless @installed
      safely { @provider.enter }
    end

    # Restores the bound window's previous presentation.
    def exit(native_window : Void* = Pointer(Void).null) : Nil
      install(native_window) if !native_window.null? && !@installed
      return unless @installed
      safely { @provider.exit }
    end

    # Returns whether kiosk presentation is active.
    def active? : Bool
      @installed && (@provider.active? rescue false)
    end

    # Restores the window and releases native resources.
    def cleanup : Nil
      safely { @provider.cleanup }
      @installed = false
    end

    private def safely(&block : ->) : Bool
      block.call
      true
    rescue ex
      Log.warn(exception: ex) { "kiosk operation failed" }
      false
    end
  end
end
