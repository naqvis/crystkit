require "log"
require "native_desktop"
require "../platform/icon_source"

module CrystKit::Features
  # Taskbar progress and overlay indicators for the primary application window.
  class TaskbarProgress
    Log = ::Log.for(self)

    enum ProgressState
      NoProgress
      Indeterminate
      Normal
      Error
      Paused
    end

    # :nodoc:
    abstract class Provider
      abstract def attach(window : Void*, application_id : String) : Nil
      abstract def progress=(value : Float64) : Nil
      abstract def clear_progress : Nil
      abstract def badge=(text : String?) : Nil
      abstract def overlay_icon=(icon : ::CrystKit::Platform::IconSource?) : Nil
      abstract def state=(state : ProgressState) : Nil
      abstract def cleanup : Nil
    end

    # :nodoc:
    class NativeProvider < Provider
      @taskbar : ::NativeDesktop::Taskbar?

      def attach(window : Void*, application_id : String) : Nil
        @taskbar.try(&.cleanup)
        @taskbar = ::NativeDesktop::Taskbar.new(window, application_id)
      end

      def progress=(value : Float64) : Nil
        @taskbar.try { |taskbar| taskbar.progress = value }
      end

      def clear_progress : Nil
        @taskbar.try(&.clear_progress)
      end

      def badge=(text : String?) : Nil
        @taskbar.try { |taskbar| taskbar.badge = text }
      end

      def overlay_icon=(icon : ::CrystKit::Platform::IconSource?) : Nil
        native = if bytes = icon.try(&.bytes)
                   ::NativeDesktop::TaskbarIcon.bytes(bytes)
                 elsif name = icon.try(&.name)
                   ::NativeDesktop::TaskbarIcon.name(name)
                 end
        @taskbar.try { |taskbar| taskbar.overlay_icon = native }
      end

      def state=(state : ProgressState) : Nil
        @taskbar.try { |taskbar| taskbar.state = ::NativeDesktop::TaskbarProgressState.from_value(state.value) }
      end

      def cleanup : Nil
        @taskbar.try(&.cleanup)
        @taskbar = nil
      end
    end

    getter progress : Float64 = 0.0
    getter progress_state : ProgressState = ProgressState::NoProgress
    getter badge : String?
    getter overlay_icon : ::CrystKit::Platform::IconSource?
    getter? installed : Bool = false

    def initialize(@provider : Provider = NativeProvider.new)
    end

    # :nodoc:
    def install(window : Void*, application_id : String) : Nil
      return if window.null?
      return unless safely { @provider.attach(window, application_id) }
      @installed = true
      safely do
        @provider.state = @progress_state
        @provider.progress = @progress unless @progress_state.no_progress?
        @provider.badge = @badge
        @provider.overlay_icon = @overlay_icon
      end
    end

    # Sets progress after clamping it to `0.0..1.0`.
    def progress=(value : Float64) : Nil
      return unless value.finite?
      @progress = value.clamp(0.0, 1.0)
      safely { @provider.progress = @progress } if @installed
    end

    # Removes the progress indicator and resets its cached value and state.
    def clear_progress : Nil
      @progress = 0.0
      @progress_state = ProgressState::NoProgress
      safely { @provider.clear_progress } if @installed
    end

    # Sets a textual badge, or clears it with `nil`.
    def badge=(text : String?) : Nil
      @badge = text
      safely { @provider.badge = text } if @installed
    end

    # Sets an overlay icon, or clears it with `nil`.
    def overlay_icon=(icon : ::CrystKit::Platform::IconSource?) : Nil
      @overlay_icon = icon
      safely { @provider.overlay_icon = icon } if @installed
    end

    # Sets the progress indicator's visual state.
    def progress_state=(state : ProgressState) : Nil
      @progress_state = state
      safely { @provider.state = state } if @installed
    end

    # Releases native resources owned by this controller.
    def cleanup : Nil
      safely { @provider.cleanup }
      @installed = false
    end

    private def safely(&block : ->) : Bool
      block.call
      true
    rescue ex
      Log.warn(exception: ex) { "taskbar operation failed" }
      false
    end
  end
end
