require "log"
require "./init"

module CrystKit
  module Platform
    module Windows
      lib LibUser32ClosePrevent
        fun CallWindowProcW(lp_prev_wnd_func : Int64, h_wnd : Void*, msg : UInt32, w_param : UInt64, l_param : Int64) : Int64
        fun GetWindowLongPtrW(h_wnd : Void*, n_index : Int32) : Int64
        fun SetWindowLongPtrW(h_wnd : Void*, n_index : Int32, dw_new_long : Int64) : Int64
      end

      lib LibWebView2Color
        struct COREWEBVIEW2_COLOR
          a : UInt8
          r : UInt8
          g : UInt8
          b : UInt8
        end
      end

      module EnhancedWindow
        extend self

        Log = ::Log.for(self)

        @@transparent_windows = Set(Void*).new

        GWLP_WNDPROC = -4

        # Close-to-hide (minimize-to-tray) is a no-op on Windows.
        def enable_close_to_hide(native_window : Void*) : Nil
        end

        def disable_close_to_hide(native_window : Void*) : Nil
        end

        # Store original window procs for close prevention subclassing.
        @@close_prevent_original_procs = {} of Void* => Int64
        @@close_prevent_proc : (Void*, UInt32, UInt64, Int64 -> Int64)? = nil

        # No webview-specific focus adjustments needed on Windows.
        def after_focus(window : Void*) : Nil
        end

        def enable_close_prevention(native_window : Void*) : Nil
          return if native_window.null?
          return if @@close_prevent_original_procs.has_key?(native_window)

          original = LibUser32ClosePrevent.GetWindowLongPtrW(native_window, GWLP_WNDPROC)
          @@close_prevent_original_procs[native_window] = original

          if @@close_prevent_proc.nil?
            @@close_prevent_proc = ->(hwnd : Void*, msg : UInt32, wparam : UInt64, lparam : Int64) : Int64 {
              if msg == 0x0010 # WM_CLOSE
                ew = CrystKit::Core::EnhancedWindow.lookup(hwnd)
                if ew && !ew.handle_close_request
                  return 0_i64 # Prevent close
                end
                orig = @@close_prevent_original_procs.delete(hwnd) || 0_i64
                if orig != 0
                  LibUser32ClosePrevent.SetWindowLongPtrW(hwnd, GWLP_WNDPROC, orig)
                  return LibUser32ClosePrevent.CallWindowProcW(orig, hwnd, msg, wparam, lparam)
                end
              end
              orig = @@close_prevent_original_procs[hwnd]?
              if orig
                LibUser32ClosePrevent.CallWindowProcW(orig, hwnd, msg, wparam, lparam)
              else
                LibUser32.DefWindowProcW(hwnd, msg, wparam, lparam)
              end
            }
          end

          proc_ptr = @@close_prevent_proc.not_nil!
          LibUser32ClosePrevent.SetWindowLongPtrW(native_window, GWLP_WNDPROC, proc_ptr.pointer.address)
        end

        def disable_close_prevention(native_window : Void*) : Nil
          orig = @@close_prevent_original_procs.delete(native_window) || 0_i64
          return if orig == 0
          LibUser32ClosePrevent.SetWindowLongPtrW(native_window, GWLP_WNDPROC, orig)
        end

        # WebView2 ICoreWebView2Controller2 transparent background.
        def set_webview_background(window : Void*, transparent : Bool) : Nil
          if transparent
            apply_webview_transparent_background(window)
          end
        end

        # WebView2 ICoreWebView2Controller2 vtable layout:
        #   0  QueryInterface, 1 AddRef, 2 Release   (IUnknown)
        #   3..25 ICoreWebView2Controller own methods
        #   26 get_DefaultBackgroundColor           (ICoreWebView2Controller2)
        #   27 put_DefaultBackgroundColor(this, COREWEBVIEW2_COLOR)
        PUT_DEFAULT_BG_COLOR_VTABLE_INDEX = 27

        # IID_ICoreWebView2Controller2 = {c979903e-d4ca-4228-92eb-47ee3fa96eab}
        IID_ICOREWEBVIEW2_CONTROLLER_2 = Bytes[
          0x3e, 0x90, 0x79, 0xc9, 0xca, 0xd4, 0x28, 0x42,
          0x92, 0xeb, 0x47, 0xee, 0x3f, 0xa9, 0x6e, 0xab,
        ]

        def apply_webview_transparent_background(window : Void*) : Nil
          controller = webview_controller(window)
          return if controller.null?
          controller2 = query_interface_iid(controller, IID_ICOREWEBVIEW2_CONTROLLER_2)
          return if controller2.null?
          begin
            vtable = controller2.as(Pointer(Pointer(Void))).value
            fn_ptr = vtable.as(Pointer(Pointer(Void)))[PUT_DEFAULT_BG_COLOR_VTABLE_INDEX]
            return if fn_ptr.null?
            storage = uninitialized UInt64[2]
            storage[0] = fn_ptr.address
            storage[1] = 0_u64
            transparent = LibWebView2Color::COREWEBVIEW2_COLOR.new(a: 0_u8, r: 0_u8, g: 0_u8, b: 0_u8)
            put_bg = storage.to_unsafe.as(Pointer(Pointer(Void), LibWebView2Color::COREWEBVIEW2_COLOR -> Int32)).value
            hr = put_bg.call(controller2, transparent)
            Log.warn { "EnhancedWindow[Windows]: put_DefaultBackgroundColor failed: HRESULT=#{hr}" } if hr < 0
          ensure
            com_release(controller2)
          end
        end

        # Reach the ICoreWebView2Controller behind *window* via the registry.
        def webview_controller(window : Void*) : Void*
          return Pointer(Void).null if window.null?
          if ew = CrystKit::Core::EnhancedWindow.lookup(window)
            return ew.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER)
          end
          Pointer(Void).null
        end

        def query_interface_iid(obj : Void*, iid : Bytes) : Void*
          return Pointer(Void).null if obj.null?
          vtable = obj.as(Pointer(Pointer(Void))).value.as(Pointer(Pointer(Void)))
          qi_ptr = vtable[0]
          return Pointer(Void).null if qi_ptr.null?
          storage = uninitialized UInt64[2]
          storage[0] = qi_ptr.address
          storage[1] = 0_u64
          qi = storage.to_unsafe.as(Pointer(Pointer(Void), UInt8*, Pointer(Pointer(Void)) -> Int32)).value
          out_ptr = Pointer(Void).null
          hr = qi.call(obj, iid.to_unsafe.as(UInt8*), pointerof(out_ptr))
          (hr >= 0) ? out_ptr : Pointer(Void).null
        end

        def com_release(obj : Void*) : UInt32
          return 0_u32 if obj.null?
          vtable = obj.as(Pointer(Pointer(Void))).value.as(Pointer(Pointer(Void)))
          rel_ptr = vtable[2]
          return 0_u32 if rel_ptr.null?
          storage = uninitialized UInt64[2]
          storage[0] = rel_ptr.address
          storage[1] = 0_u64
          rel = storage.to_unsafe.as(Pointer(Pointer(Void) -> UInt32)).value
          rel.call(obj)
        end

        # Track transparent windows and apply WebView2 background during init.
        def track_transparent(window : Void*) : Nil
          @@transparent_windows << window unless window.null?
        end
      end
    end
  end
end
