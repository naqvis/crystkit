require "../core/window_factory"

module CrystKit
  module Test
    # A `Platform::WindowBackend` that builds `Core::EnhancedWindow`
    # instances **without** the native webview engine, so specs can create
    # and wire windows on a headless CI box (no display required).
    #
    # It relies on the test-only `EnhancedWindow` constructor
    # (`initialize(debug, title, label, _fake : Bool)`), which leaves the
    # native handle null. Every native-touching method on that instance is
    # then a safe no-op, while the window still flows through the normal
    # `App#window` → `WindowRegistry` → `wire_window` pipeline.
    #
    # ```
    # services = CrystKit::Platform::Services.new(
    #   window: CrystKit::Test::FakeWindowBackend.new,
    # )
    # app = CrystKit::App.new(config, platform: services)
    # win = app.window(title: "Main", label: "main", html: "<h1>Hi</h1>")
    # ```
    class FakeWindowBackend < ::CrystKit::Platform::WindowBackend
      # Creates a null-handle `EnhancedWindow` carrying the supplied
      # geometry and visibility. Like the real backend, the window is
      # hidden before being returned when *visible* is `false`.
      def create_window(
        title : String,
        width : Int32,
        height : Int32,
        hint : ::Webview::SizeHints,
        debug : Bool,
        label : String?,
        visible : Bool,
      ) : ::CrystKit::Core::EnhancedWindow
        wv = ::CrystKit::Core::EnhancedWindow.fake(debug, title, label)
        wv.size(width, height, hint)
        wv.title = title
        wv.hide_now unless visible
        wv
      end

      # Records nothing and loads no content — the fake window never
      # navigates or renders.
      def configure_content(window : ::CrystKit::Core::EnhancedWindow, url : String?, html : String?) : Nil
      end
    end
  end
end
