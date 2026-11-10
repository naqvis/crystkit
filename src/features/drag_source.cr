require "log"
require "../core/errors"
require "../security/capability"
require "native_desktop"

module CrystKit::Features
  class DragSource
    Log = ::Log.for(self)

    @native : NativeDesktop::DragSource?
    @window_handle = Pointer(Void).null

    def initialize(@capabilities : Security::CapabilitySystem? = nil)
    end

    def attach(window : ::CrystKit::Core::Window) : Nil
      handle = window.window
      return if !handle.null? && handle == @window_handle && !@native.nil?

      @native.try(&.close)
      @native = nil
      @window_handle = Pointer(Void).null
      return if handle.null?

      native_window = NativeDesktop::Window.attach(window.window)
      @native = NativeDesktop::DragSource.new(native_window)
      @window_handle = handle
    end

    def cleanup : Nil
      @native.try(&.close)
      @native = nil
      @window_handle = Pointer(Void).null
    end

    def start_file_drag(path : String) : Bool
      @capabilities.try(&.require!("drag:source"))
      source = @native
      return false unless source
      source.start(NativeDesktop::DragPayload.file(path))
    end

    def start_text_drag(text : String) : Bool
      @capabilities.try(&.require!("drag:source"))
      source = @native
      return false unless source
      source.start(NativeDesktop::DragPayload.text(text))
    end

    def start_url_drag(url : String) : Bool
      @capabilities.try(&.require!("drag:source"))
      source = @native
      return false unless source
      source.start(NativeDesktop::DragPayload.url(url))
    end

    def start_image_drag(path : String) : Bool
      @capabilities.try(&.require!("drag:source"))
      source = @native
      return false unless source
      source.start(NativeDesktop::DragPayload.image(path))
    end
  end
end
