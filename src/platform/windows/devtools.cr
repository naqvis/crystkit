require "log"
require "../../core/errors"
require "./init"

module CrystKit::Platform::Windows::DevTools
  extend self

  @[Link("ole32")]
  @[Link("oleaut32")]
  lib LibWebView2DevTools
    type ICoreWebView2 = Void*
    type HWND = Void*

    # ICoreWebView2 vtable index for OpenDevToolsWindow.
    # Slot 84 (0-indexed after IUnknown) in ICoreWebView2.
    OPEN_DEV_TOOLS_VTABLE_INDEX = 84

    # ICoreWebView2Controller vtable index for get_CoreWebView2.
    # Slot 27 (0-indexed after IUnknown) in ICoreWebView2Controller.
    GET_CORE_WEBVIEW2_VTABLE_INDEX = 27
  end

  # Dock mode constants matching DevToolsDockMode enum values:
  #   0 = Undocked, 1 = Bottom, 2 = Right, 3 = Left
  # On Windows/WebView2 all modes open a floating DevTools window.
  DOCK_UNDOCKED = 0
  DOCK_BOTTOM   = 1
  DOCK_RIGHT    = 2
  DOCK_LEFT     = 3

  # Open the WebView2 DevTools window.
  #
  # *native_window* should be the ICoreWebView2Controller pointer obtained
  # via `webview_get_native_handle(w, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER)`.
  # *dock_mode* is accepted for API consistency but has no effect on Windows.
  def open(native_window : Pointer(Void), dock_mode : Int32) : Nil
    return if native_window.null?

    begin
      # Step 1: Get ICoreWebView2* from ICoreWebView2Controller*.
      # ICoreWebView2Controller vtable[27] = get_CoreWebView2(controller, &webview) -> HRESULT
      ctrl_vtbl = native_window.as(Pointer(Pointer(Pointer(Void)))).value
      get_cv2_fn = ctrl_vtbl[LibWebView2DevTools::GET_CORE_WEBVIEW2_VTABLE_INDEX]

      # Manually construct the Proc struct (MSVC-safe): [func_ptr, nil_closure]
      get_cv2_storage = uninitialized UInt64[2]
      get_cv2_storage[0] = get_cv2_fn.address
      get_cv2_storage[1] = 0_u64
      get_cv2 = get_cv2_storage.to_unsafe.as(Pointer(Pointer(Void), Pointer(Pointer(Void)) -> Int32)).value

      webview = Pointer(Void).null
      hr = get_cv2.call(native_window, pointerof(webview))

      if hr < 0 || webview.null?
        Log.warn { "DevTools[Windows]: get_CoreWebView2 returned HRESULT 0x#{hr.to_s(16)}" }
        return
      end

      # Step 2: Call OpenDevToolsWindow on ICoreWebView2*.
      # ICoreWebView2 vtable[84] = OpenDevToolsWindow(webview) -> HRESULT
      wv_vtbl = webview.as(Pointer(Pointer(Pointer(Void)))).value
      open_fn_ptr = wv_vtbl[LibWebView2DevTools::OPEN_DEV_TOOLS_VTABLE_INDEX]

      open_storage = uninitialized UInt64[2]
      open_storage[0] = open_fn_ptr.address
      open_storage[1] = 0_u64
      open_fn = open_storage.to_unsafe.as(Pointer(Pointer(Void) -> Int32)).value

      hr = open_fn.call(webview)

      if hr < 0
        Log.warn { "DevTools[Windows]: OpenDevToolsWindow returned HRESULT 0x#{hr.to_s(16)}" }
      else
        Log.debug { "DevTools[Windows]: DevTools window opened" }
      end
    rescue ex
      Log.error { "DevTools[Windows]: failed to open DevTools: #{ex.message}" }
    end
  end

  # Close the WebView2 DevTools window.
  #
  # WebView2 does not expose a public CloseDevToolsWindow API.
  # The DevTools window can only be closed by the user or by destroying
  # the WebView2 controller. We log a warning and do nothing.
  def close(native_window : Pointer(Void)) : Nil
    Log.debug { "DevTools[Windows]: close() — WebView2 DevTools window must be closed by the user" }
  end
end
