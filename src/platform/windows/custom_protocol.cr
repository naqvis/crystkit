require "log"
require "../../core/errors"
require "./init"

module CrystKit::Platform::Windows::CustomProtocol
  extend self

  @@resolver : Proc(String, {Bytes, String}?)?
  @@env : Void* = Pointer(Void).null
  @@handler_obj : Void* = Pointer(Void).null
  @@handler_vtbl : Void* = Pointer(Void).null

  S_OK          =           0_i32
  S_FALSE       =           1_i32
  E_NOINTERFACE = -2147467262_i32
  E_INVALIDARG  = -2147024809_i32

  COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL = 0_i32

  IDX_GET_CORE_WEBVIEW2       = 25
  IDX_ADD_WEB_RESOURCE_REQ    = 55
  IDX_ADD_WEB_RESOURCE_FILTER = 57
  IDX_GET_ENVIRONMENT         = 67
  IDX_CREATE_RESPONSE         =  4
  IDX_GET_REQUEST             =  3
  IDX_PUT_RESPONSE            =  5
  IDX_GET_URI                 =  3
  IDX_QUERY_INTERFACE         =  0
  IDX_RELEASE                 =  2

  IID_ICORE_WEBVIEW2_WEB_RESOURCE_REQUESTED_EVENT_HANDLER = Bytes[
    0x4c_u8, 0xb7, 0x00, 0xab, 0xf1, 0x15, 0x46, 0x46,
    0x80, 0xe8, 0xe7, 0x63, 0x41, 0xd2, 0x5d, 0x71,
  ]
  IID_ICORE_WEBVIEW2_2 = Bytes[
    0xf8_u8, 0x0c, 0x8f, 0x9e, 0x70, 0xe6, 0x5e, 0x4b,
    0xb2, 0xbc, 0x73, 0xe0, 0x61, 0xe3, 0x18, 0x4c,
  ]

  # ── Proc type aliases for COM methods ─────────────────────────────────

  alias Fn0Out = Void*, Pointer(Void*) -> Int32
  alias Fn1Arg = Void*, Void* -> Int32
  alias Fn1ArgI32 = Void*, Void*, Int32 -> Int32
  alias Fn1ArgToken = Void*, Void*, UInt64* -> Int32
  alias FnWideOut = Void*, Pointer(UInt16*) -> Int32
  alias FnCreateRes = Void*, Void*, Int32, UInt16*, UInt16*, Pointer(Void*) -> Int32
  alias FnQI = Void*, Void*, Pointer(Void*) -> Int32
  alias FnRelease = Void* -> UInt32

  # ── Vtable access ─────────────────────────────────────────────────────

  private def vtable_at(obj : Void*, index : Int32) : Void*
    obj.as(Pointer(Void*)).value.as(Pointer(Void*))[index]
  end

  # Read a vtable entry as a callable Crystal Proc using the buffer trick.
  #
  # Crystal Proc = {func_ptr (8 bytes), closure_data (8 bytes)} = 16 bytes total.
  # We store the function address at buf[0] and zero closure at buf[1].
  # Reading 16 bytes back gives a correctly constructed Proc.
  private macro make_proc(obj, index, type)
    begin
      addr = vtable_at({{ obj }}, {{ index }})
      buf = uninitialized UInt64[2]
      buf[0] = addr.address
      buf[1] = 0_u64
      buf.to_unsafe.as(Pointer({{ type }})).value
    end
  end

  # ── COM dispatchers ───────────────────────────────────────────────────

  private def com_get_core_webview2(controller : Void*) : Void*
    return Pointer(Void).null if controller.null?
    fn = make_proc(controller, IDX_GET_CORE_WEBVIEW2, Fn0Out)
    out = Pointer(Void).null
    hr = fn.call(controller, pointerof(out))
    hr >= 0 ? out : Pointer(Void).null
  end

  private def com_query_interface(obj : Void*, iid : Bytes) : Void*
    return Pointer(Void).null if obj.null?
    fn = make_proc(obj, IDX_QUERY_INTERFACE, FnQI)
    out = Pointer(Void).null
    hr = fn.call(obj, iid.to_unsafe.as(Void*), pointerof(out))
    hr >= 0 ? out : Pointer(Void).null
  end

  private def com_release(obj : Void*) : Nil
    return if obj.null?
    fn = make_proc(obj, IDX_RELEASE, FnRelease)
    fn.call(obj)
  end

  private def com_get_environment(sender : Void*) : Void*
    return Pointer(Void).null if sender.nil?
    sender2 = com_query_interface(sender, IID_ICORE_WEBVIEW2_2)
    return Pointer(Void).null if sender2.nil?

    fn = make_proc(sender2, IDX_GET_ENVIRONMENT, Fn0Out)
    out = Pointer(Void).null
    hr = fn.call(sender2, pointerof(out))
    com_release(sender2)
    hr >= 0 ? out : Pointer(Void).null
  end

  private def com_add_web_resource_requested(webview : Void*, handler : Void*) : Int32
    return -1 if webview.nil?
    fn = make_proc(webview, IDX_ADD_WEB_RESOURCE_REQ, Fn1ArgToken)
    token = uninitialized UInt64
    fn.call(webview, handler, pointerof(token))
  end

  private def com_add_web_resource_requested_filter(webview : Void*, uri : Void*) : Int32
    return -1 if webview.nil?
    fn = make_proc(webview, IDX_ADD_WEB_RESOURCE_FILTER, Fn1ArgI32)
    fn.call(webview, uri, COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL)
  end

  private def com_get_request(args : Void*) : Void*
    return Pointer(Void).null if args.nil?
    fn = make_proc(args, IDX_GET_REQUEST, Fn0Out)
    out = Pointer(Void).null
    fn.call(args, pointerof(out)) >= 0 ? out : Pointer(Void).null
  end

  private def com_put_response(args : Void*, response : Void*) : Bool
    return false if args.nil? || response.nil?
    fn = make_proc(args, IDX_PUT_RESPONSE, Fn1Arg)
    fn.call(args, response) >= 0
  end

  private def com_get_request_uri(request : Void*) : String?
    return nil if request.nil?
    fn = make_proc(request, IDX_GET_URI, FnWideOut)
    out_wide = Pointer(UInt16).null
    hr = fn.call(request, pointerof(out_wide))
    return nil if hr < 0 || out_wide.nil?
    str, _ = String.from_utf16(out_wide)
    LibOLE.CoTaskMemFree(out_wide)
    str
  end

  private def com_create_response(env : Void*, stream : Void*, status : Int32, reason : UInt16*, headers : UInt16*) : Void*
    return Pointer(Void).null if env.nil?
    fn = make_proc(env, IDX_CREATE_RESPONSE, FnCreateRes)
    out = Pointer(Void).null
    hr = fn.call(env, stream, status, reason, headers, pointerof(out))
    hr >= 0 ? out : Pointer(Void).null
  end

  # ── Handler COM object ──────────────────────────────────────────────

  private def com_obj_add_ref(obj : Void*) : UInt32
    ref = obj.as(Pointer(Int32))[2]
    ref += 1
    obj.as(Pointer(Int32))[2] = ref
    ref.to_u32!
  end

  private def com_obj_release(obj : Void*) : UInt32
    ref = obj.as(Pointer(Int32))[2]
    ref -= 1
    obj.as(Pointer(Int32))[2] = ref
    ref.to_u32!
  end

  private def create_handler : Void*
    return @@handler_obj unless @@handler_obj.null?

    vtbl = Pointer(Void*).malloc(4)

    vtbl[0] = ->(this : Void*, riid : Void*, ppv : Pointer(Void*)) : Int32 {
      return E_INVALIDARG if ppv.null? || riid.null?
      ppv.value = Pointer(Void).null

      iid = riid.as(UInt8*)
      iid_unknown = Bytes[
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,
      ]
      match_unknown = true
      16.times do |i|
        if iid[i] != iid_unknown[i]
          match_unknown = false
          break
        end
      end
      if match_unknown
        ppv.value = this
        com_obj_add_ref(this)
        return S_OK
      end

      match_handler = true
      iid_handler = IID_ICORE_WEBVIEW2_WEB_RESOURCE_REQUESTED_EVENT_HANDLER
      16.times do |i|
        if iid[i] != iid_handler[i]
          match_handler = false
          break
        end
      end
      if match_handler
        ppv.value = this
        com_obj_add_ref(this)
        return S_OK
      end

      E_NOINTERFACE
    }.pointer.as(Void*)

    vtbl[1] = ->(this : Void*) : UInt32 {
      com_obj_add_ref(this)
    }.pointer.as(Void*)

    vtbl[2] = ->(this : Void*) : UInt32 {
      com_obj_release(this)
    }.pointer.as(Void*)

    vtbl[3] = ->(this : Void*, sender : Void*, args : Void*) : Int32 {
      req = com_get_request(args)
      if req.nil?
        return S_OK
      end

      uri_str = com_get_request_uri(req)
      com_release(req)
      if uri_str.nil?
        return S_OK
      end

      if r = @@resolver
        result = r.call(uri_str)
        if result
          bytes, mime_str = result

          hmem = LibKernel32.GlobalAlloc(LibKernel32::GMEM_MOVEABLE, bytes.size.to_u64)
          if hmem.null?
            return S_OK
          end
          ptr = LibKernel32.GlobalLock(hmem)
          if ptr.null?
            return S_OK
          end
          ptr.as(UInt8*).copy_from(bytes.to_unsafe, bytes.size)
          LibKernel32.GlobalUnlock(hmem)

          stream_out = Pointer(Void).null
          hr = LibOLE.CreateStreamOnHGlobal(hmem, 1, pointerof(stream_out))
          if hr < 0 || stream_out.null?
            return S_OK
          end

          headers_utf16 = "Content-Type: #{mime_str}\r\n".encode("UTF-16LE") + Bytes[0, 0]
          reason_utf16 = "OK".encode("UTF-16LE") + Bytes[0, 0]

          env = @@env
          if env.null?
            return S_OK
          end

          response = com_create_response(env, stream_out, 200, reason_utf16.to_unsafe.as(UInt16*), headers_utf16.to_unsafe.as(UInt16*))
          if response.null?
            return S_OK
          end

          com_put_response(args, response)
          com_release(response)
        else
          headers_utf16 = "Content-Type: text/plain\r\n".encode("UTF-16LE") + Bytes[0, 0]
          reason_utf16 = "Not Found".encode("UTF-16LE") + Bytes[0, 0]

          env = @@env
          if env
            response = com_create_response(env, Pointer(Void).null, 404, reason_utf16.to_unsafe.as(UInt16*), headers_utf16.to_unsafe.as(UInt16*))
            if response
              com_put_response(args, response)
              com_release(response)
            end
          end
        end
      end

      S_OK
    }.pointer.as(Void*)

    obj = Pointer(Void*).malloc(2)
    obj.value = vtbl.as(Void*)
    obj.as(Pointer(Int32))[2] = 1

    @@handler_vtbl = vtbl.as(Void*)
    @@handler_obj = obj.as(Void*)
    @@handler_obj
  end

  # ── Public API ───────────────────────────────────────────────────────

  def setup(scheme : String, resolver : Proc(String, {Bytes, String}?)) : Nil
    @@resolver = resolver
  end

  def register(wv : T, scheme : String, resolver : Proc(String, {Bytes, String}?)) : Nil forall T
    Init.ensure_com
    @@resolver = resolver
    host = "#{scheme}.localhost"

    controller = wv.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER)
    if controller.null?
      Log.warn { "CustomProtocol[Windows]: BROWSER_CONTROLLER handle is null" }
      return
    end

    webview = com_get_core_webview2(controller)
    if webview.null?
      Log.warn { "CustomProtocol[Windows]: get_CoreWebView2 failed" }
      return
    end

    webview2 = com_query_interface(webview, IID_ICORE_WEBVIEW2_2)
    if webview2.null?
      Log.warn { "CustomProtocol[Windows]: QI for ICoreWebView2_2 failed" }
      com_release(webview)
      return
    end
    com_release(webview)
    webview = webview2

    env = com_get_environment(webview)
    if env.null?
      Log.warn { "CustomProtocol[Windows]: get_Environment failed on webview" }
      com_release(webview)
      return
    end
    @@env = env

    handler = create_handler
    if handler.null?
      com_release(webview)
      return
    end

    filter_uri = "https://#{host}/*\0"
    wide_bytes = filter_uri.encode("UTF-16LE")
    hr_filter = com_add_web_resource_requested_filter(webview, wide_bytes.to_unsafe.as(Void*))
    if hr_filter < 0
      Log.warn { "CustomProtocol[Windows]: AddWebResourceRequestedFilter failed hr=0x#{hr_filter.to_s(16)}" }
    end

    hr_add = com_add_web_resource_requested(webview, handler)
    if hr_add < 0
      Log.warn { "CustomProtocol[Windows]: add_WebResourceRequested failed hr=0x#{hr_add.to_s(16)}" }
    end

    com_release(webview)
  end
end
