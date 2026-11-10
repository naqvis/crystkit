require "webview"

module CrystKit::Core
  # Stateless helper for constructing platform-native webview windows.
  #
  # Every call returns a fresh, independent window. Window registration,
  # IPC wiring, and lifecycle hook installation are performed by `App`.
  module WindowFactory
    extend self

    # Create and return a new `EnhancedWindow` with the given geometry.
    #
    # When *visible* is `false`, the window is hidden before it is returned
    # to avoid a visible flash.
    #
    # The returned window has no content set and no IPC wiring — call
    # `#configure_content` to load a URL or HTML string.
    #
    # ```
    # wv = WindowFactory.create_window(title: "Splash", visible: false)
    # WindowFactory.configure_content(wv, html: "<h1>Booting…</h1>")
    # ```
    def create_window(
      title : String = "Window",
      width : Int32 = 800,
      height : Int32 = 600,
      hint : SizeHints = SizeHints::NONE,
      debug : Bool = false,
      label : String? = nil,
      visible : Bool = true,
    ) : ::CrystKit::Core::EnhancedWindow
      wv = ::CrystKit::Core::EnhancedWindow.new(debug, title, label)
      wv.size(width, height, hint)
      wv.title = title
      wv.hide_now unless visible
      wv
    end

    # Load initial content into *wv* from either an HTML string or a URL.
    #
    # When both are given, *html* takes precedence. When neither is
    # supplied the call is a no-op.
    def configure_content(wv : ::CrystKit::Core::EnhancedWindow, url : String? = nil, html : String? = nil) : Nil
      if html
        wv.html = html
      elsif url
        wv.navigate(url)
      end
    end
  end
end
