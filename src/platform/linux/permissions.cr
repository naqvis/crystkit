require "log"
require "./lib_glib"
require "./init"

module CrystKit::Platform::Linux::Permissions
  extend self

  {% if `pkg-config --exists webkit2gtk-4.1 2>/dev/null && echo yes`.strip == "yes" %}
    @[Link("webkit2gtk-4.1")]
  {% else %}
    @[Link("webkit2gtk-4.0")]
  {% end %}
  @[Link("glib-2.0")]
  @[Link("gobject-2.0")]
  lib LibWebKitPerm
    fun webkit_permission_request_allow(request : Void*) : Nil
    fun webkit_permission_request_deny(request : Void*) : Nil
    fun webkit_geolocation_permission_request_get_type : UInt64
    fun webkit_user_media_permission_request_get_type : UInt64
    fun webkit_notification_permission_request_get_type : UInt64
    fun webkit_pointer_lock_permission_request_get_type : UInt64
    fun webkit_web_view_get_uri(web_view : Void*) : UInt8*
  end

  @@handler : Proc(String, String, String)?
  @@connected = false

  def register(wv : ::CrystKit::Webview, &handler : String, String -> String) : Nil
    @@handler = handler
    connect_signal(wv)
  end

  def register(wv : ::CrystKit::Webview, handler : Proc(String, String, String)) : Nil
    @@handler = handler
    connect_signal(wv)
  end

  private def connect_signal(wv : ::CrystKit::Webview) : Nil
    return if @@connected

    web_view = wv.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER)
    return if web_view.null?

    LibGObject.g_signal_connect_data(
      web_view,
      "permission-request".to_unsafe,
      ->(_webview_arg : Void*, request : Void*, _user_data : Void*) {
        handle_permission_request(web_view, request)
        1
      }.pointer,
      Pointer(Void).null,
      Pointer(Void).null,
      0_i32,
    )

    @@connected = true
    Log.debug { "Permissions[Linux]: connected to permission-request signal" }
  end

  private def handle_permission_request(web_view : Void*, request : Void*) : Nil
    geo_type = LibWebKitPerm.webkit_geolocation_permission_request_get_type
    media_type = LibWebKitPerm.webkit_user_media_permission_request_get_type
    notif_type = LibWebKitPerm.webkit_notification_permission_request_get_type
    pointer_type = LibWebKitPerm.webkit_pointer_lock_permission_request_get_type

    origin_uri = LibWebKitPerm.webkit_web_view_get_uri(web_view)
    origin = origin_uri.null? ? "unknown://unknown" : String.new(origin_uri)

    if LibGObject.g_type_check_instance_is_a(request, geo_type) != 0
      resolve_and_apply(request, origin, "geolocation")
    elsif LibGObject.g_type_check_instance_is_a(request, media_type) != 0
      resolve_and_apply(request, origin, "camera")
      resolve_and_apply(request, origin, "microphone")
    elsif LibGObject.g_type_check_instance_is_a(request, notif_type) != 0
      resolve_and_apply(request, origin, "notifications")
    elsif LibGObject.g_type_check_instance_is_a(request, pointer_type) != 0
      resolve_and_apply(request, origin, "pointer_lock")
    else
      if h = @@handler
        h.call(origin, "unknown")
      end
      LibWebKitPerm.webkit_permission_request_allow(request)
    end
  end

  private def resolve_and_apply(request : Void*, origin : String, type : String) : Nil
    if h = @@handler
      case h.call(origin, type).downcase
      when "granted"
        LibWebKitPerm.webkit_permission_request_allow(request)
      when "denied"
        LibWebKitPerm.webkit_permission_request_deny(request)
      else
        LibWebKitPerm.webkit_permission_request_allow(request)
      end
    else
      LibWebKitPerm.webkit_permission_request_allow(request)
    end
  end
end
