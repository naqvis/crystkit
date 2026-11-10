require "log"
require "../../core/errors"
require "./init"

module CrystKit::Platform::Linux::DevTools
  extend self

  {% if `pkg-config --exists webkit2gtk-4.1 2>/dev/null && echo yes`.strip == "yes" %}
    @[Link("webkit2gtk-4.1")]
  {% else %}
    @[Link("webkit2gtk-4.0")]
  {% end %}
  lib LibWebKitInspector
    type WebKitWebView = Void*
    type WebKitWebInspector = Void*

    fun webkit_web_view_get_inspector(web_view : WebKitWebView) : WebKitWebInspector
    fun webkit_web_inspector_show(inspector : WebKitWebInspector) : Nil
    fun webkit_web_inspector_close(inspector : WebKitWebInspector) : Nil
    fun webkit_web_inspector_detach(inspector : WebKitWebInspector) : Nil
    fun webkit_web_inspector_attach(inspector : WebKitWebInspector) : Nil
  end

  # Dock mode constants matching DevToolsDockMode enum values:
  #   0 = Undocked, 1 = Bottom, 2 = Right, 3 = Left
  DOCK_UNDOCKED = 0
  DOCK_BOTTOM   = 1
  DOCK_RIGHT    = 2
  DOCK_LEFT     = 3

  # Enable developer extras on a WebKitWebView via its WebKitSettings.
  # Must be called at window-creation time (before first page load).
  module DevToolsSetup
    extend self

    {% if `pkg-config --exists webkit2gtk-4.1 2>/dev/null && echo yes`.strip == "yes" %}
      @[Link("webkit2gtk-4.1")]
    {% else %}
      @[Link("webkit2gtk-4.0")]
    {% end %}
    lib LibWebKitSettings
      fun webkit_web_view_get_settings(wv : Void*) : Void*
      fun webkit_settings_set_enable_developer_extras(settings : Void*, enabled : Int32) : Nil
    end

    def enable_developer_extras(wv_ptr : Pointer(Void)) : Nil
      settings = LibWebKitSettings.webkit_web_view_get_settings(wv_ptr)
      return if settings.null?
      LibWebKitSettings.webkit_settings_set_enable_developer_extras(settings, 1)
      Log.debug { "DevTools[Linux]: enable_developer_extras set" }
    end
  end

  # Open the WebKitGTK inspector for the given WebKitWebView widget pointer.
  def open(native_widget : Pointer(Void), dock_mode : Int32) : Nil
    return if native_widget.null?

    begin
      inspector = LibWebKitInspector.webkit_web_view_get_inspector(
        native_widget.as(LibWebKitInspector::WebKitWebView)
      )
      if inspector.null?
        Log.error { "DevTools[Linux]: webkit_web_view_get_inspector returned null — is the pointer a WebKitWebView*?" }
        return
      end

      if dock_mode == DOCK_UNDOCKED
        LibWebKitInspector.webkit_web_inspector_detach(inspector)
      else
        LibWebKitInspector.webkit_web_inspector_attach(inspector)
      end

      LibWebKitInspector.webkit_web_inspector_show(inspector)
      Log.info { "DevTools[Linux]: inspector opened (dock_mode=#{dock_mode})" }
    rescue ex
      Log.error { "DevTools[Linux]: failed to open inspector: #{ex.class} — #{ex.message}" }
    end
  end

  # Close the WebKitGTK inspector.
  def close(native_widget : Pointer(Void)) : Nil
    return if native_widget.null?

    begin
      inspector = LibWebKitInspector.webkit_web_view_get_inspector(
        native_widget.as(LibWebKitInspector::WebKitWebView)
      )
      if inspector.null?
        Log.error { "DevTools[Linux]: close — inspector pointer is null" }
        return
      end

      LibWebKitInspector.webkit_web_inspector_close(inspector)
      Log.info { "DevTools[Linux]: inspector closed" }
    rescue ex
      Log.error { "DevTools[Linux]: failed to close inspector: #{ex.class} — #{ex.message}" }
    end
  end
end
