require "../../core/window_factory"

module CrystKit
  module Platform
    # Abstract interface for native window creation and content configuration.
    abstract class WindowBackend
      # Creates and returns a new `EnhancedWindow` with the given *title*,
      # dimensions, sizing *hint* (`::Webview::SizeHints`), *debug* flag,
      # optional *label*, and initial *visible* state.
      abstract def create_window(
        title : String,
        width : Int32,
        height : Int32,
        hint : SizeHints,
        debug : Bool,
        label : String?,
        visible : Bool,
      ) : ::CrystKit::Core::EnhancedWindow

      # Loads content into *window* from *url* when given, otherwise from the
      # inline *html* string.
      abstract def configure_content(window : ::CrystKit::Core::EnhancedWindow, url : String?, html : String?) : Nil
    end

    # :nodoc:
    class CurrentWindowBackend < WindowBackend
      # :nodoc:
      def create_window(title, width, height, hint, debug, label, visible) : ::CrystKit::Core::EnhancedWindow
        Core::WindowFactory.create_window(title, width, height, hint, debug, label, visible)
      end

      # :nodoc:
      def configure_content(window : ::CrystKit::Core::EnhancedWindow, url : String?, html : String?) : Nil
        Core::WindowFactory.configure_content(window, url, html)
      end
    end
  end
end
