require "log"
require "uri"
require "file_utils"
require "../../core/errors"
require "./lib_glib"
require "./init"

module CrystKit::Platform::Linux::CustomProtocol
  extend self

  {% if `pkg-config --exists webkit2gtk-4.1 2>/dev/null && echo yes`.strip == "yes" %}
    @[Link("webkit2gtk-4.1")]
  {% else %}
    @[Link("webkit2gtk-4.0")]
  {% end %}
  @[Link("glib-2.0")]
  @[Link("gio-2.0")]
  lib LibWebKit
    type WebKitWebContext = Void*
    type WebKitURISchemeRequest = Void*
    type GInputStream = Void*

    fun webkit_web_context_register_uri_scheme(
      context : WebKitWebContext,
      scheme : UInt8*,
      callback : (WebKitURISchemeRequest, Void*) -> Nil,
      user_data : Void*,
      destroy_notify : Void*,
    ) : Nil

    fun webkit_uri_scheme_request_get_uri(request : WebKitURISchemeRequest) : UInt8*

    fun webkit_uri_scheme_request_finish(
      request : WebKitURISchemeRequest,
      stream : GInputStream,
      length : Int64,
      content_type : UInt8*,
    ) : Nil

    fun webkit_uri_scheme_request_finish_error(
      request : WebKitURISchemeRequest,
      error : Void*,
    ) : Nil

    fun webkit_web_context_get_default : WebKitWebContext
  end

  @@resolver : Proc(String, {Bytes, String}?)?

  def setup(scheme : String, resolver : Proc(String, {Bytes, String}?)) : Nil
    @@resolver = resolver
  end

  def register(wv : T, scheme : String, resolver : Proc(String, {Bytes, String}?)) : Nil forall T
    Init.ensure_gtk
    @@resolver = resolver

    context = LibWebKit.webkit_web_context_get_default
    LibWebKit.webkit_web_context_register_uri_scheme(
      context,
      scheme.to_unsafe,
      ->(request : LibWebKit::WebKitURISchemeRequest, _user_data : Void*) {
        handle_scheme_request(request)
      },
      Pointer(Void).null,
      Pointer(Void).null,
    )

    Log.info { "CustomProtocol[Linux]: registered #{scheme}://" }
  end

  private def handle_scheme_request(request : LibWebKit::WebKitURISchemeRequest) : Nil
    uri_cstr = LibWebKit.webkit_uri_scheme_request_get_uri(request)
    return if uri_cstr.null?

    url = String.new(uri_cstr)

    if resolver = @@resolver
      result = resolver.call(url)
      if result
        body, mime = result
        stream = LibGIO.g_memory_input_stream_new_from_data(
          body.to_unsafe.as(Void*),
          body.size,
          Pointer(Void).null,
        )
        LibWebKit.webkit_uri_scheme_request_finish(
          request,
          stream.as(LibWebKit::GInputStream),
          body.size.to_i64,
          mime.to_unsafe,
        )
        Log.debug { "CustomProtocol[Linux]: served #{url}" }
      else
        error = LibGIO.g_error_new_literal(1_u32, 0_i32, "Not Found".to_unsafe)
        LibWebKit.webkit_uri_scheme_request_finish_error(request, error)
        Log.warn { "CustomProtocol[Linux]: 404 for #{url}" }
      end
    end
  rescue ex
    Log.error { "CustomProtocol[Linux]: handler error: #{ex.message}" }
  end
end
