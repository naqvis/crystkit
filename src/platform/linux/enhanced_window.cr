require "log"
require "./lib_glib"
require "./lib_gtk"
require "./init"

module CrystKit::Platform::Linux
  @[Link("gdk-3")]
  lib LibGDKEnhanced
    struct GdkRGBA
      red : Float64
      green : Float64
      blue : Float64
      alpha : Float64
    end
  end

  @[Link("gtk-3")]
  lib LibGTKFocus
    fun gtk_widget_grab_focus(widget : Void*) : Nil
  end

  {% if `pkg-config --exists webkit2gtk-4.1 2>/dev/null && echo yes`.strip == "yes" %}
    @[Link("webkit2gtk-4.1")]
  {% else %}
    @[Link("webkit2gtk-4.0")]
  {% end %}
  lib LibWebKitBackground
    fun webkit_web_view_set_background_color(web_view : Void*, rgba : Void*) : Nil
  end

  module EnhancedWindow
    extend self

    @@close_hide_handlers : Hash(Void*, UInt64) = {} of Void* => UInt64
    @@transparent_applied : Set(Void*) = Set(Void*).new

    def enable_close_to_hide(native_window : Void*) : Nil
      return if native_window.null?
      return if @@close_hide_handlers.has_key?(native_window)
      id = LibGObject.g_signal_connect_data(
        native_window,
        "delete-event".to_unsafe,
        ->(window : Void*, _event : Void*, _data : Void*) {
          ew = CrystKit::Core::EnhancedWindow.lookup(window)
          ew.try &.hide
          1_i32
        }.pointer,
        Pointer(Void).null,
        Pointer(Void).null,
        0_i32,
      )
      @@close_hide_handlers[native_window] = id
    end

    def disable_close_to_hide(native_window : Void*) : Nil
      return if native_window.null?
      return unless id = @@close_hide_handlers.delete(native_window)
      LibGObject.g_signal_handler_disconnect(native_window, id)
    end

    def enable_close_prevention(native_window : Void*) : Nil
      return if native_window.null?
      LibGObject.g_signal_connect_data(
        native_window,
        "delete-event".to_unsafe,
        ->(window : Void*, _event : Void*, _data : Void*) {
          ew = CrystKit::Core::EnhancedWindow.lookup(window)
          if ew && !ew.handle_close_request
            1_i32
          else
            0_i32
          end
        }.pointer,
        Pointer(Void).null,
        Pointer(Void).null,
        0_i32,
      )
    end

    # Webview-specific focus adjustments on Linux: grab focus on the WebKitWebView.
    def after_focus(window : Void*) : Nil
      webview = webview_child(window)
      LibGTKFocus.gtk_widget_grab_focus(webview) unless webview.null?
    end

    # Adjust the WebKitWebView background color to match transparency.
    def set_webview_background(window : Void*, transparent : Bool) : Nil
      return if window.null?
      webview = webview_child(window)
      return if webview.null?
      rgba = LibGDKEnhanced::GdkRGBA.new(red: 0.0, green: 0.0, blue: 0.0, alpha: transparent ? 0.0 : 1.0)
      LibWebKitBackground.webkit_web_view_set_background_color(webview, pointerof(rgba))
    end

    # Get the WebKitWebView child. gtk_bin_get_child may return an invalid
    # or non-WebKit widget. Use EnhancedWindow.lookup + native_handle to get
    # the actual m_webview pointer from the C++ engine — the only reliable
    # way to reach the WebKitWebView across GTK3/4.
    def webview_child(window : Void*) : Void*
      return Pointer(Void).null if window.null?
      if ew = CrystKit::Core::EnhancedWindow.lookup(window)
        return ew.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER)
      end
      Pointer(Void).null
    end
  end
end
