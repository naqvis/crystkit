require "log"
require "./init"

module CrystKit
  module Platform
    module Windows
      module Permissions
        extend self

        @[Link("ole32")]
        @[Link("oleaut32")]
        lib LibWebView2Perm
          COREWEBVIEW2_PERMISSION_KIND_UNKNOWN        = 0_i32
          COREWEBVIEW2_PERMISSION_KIND_MICROPHONE     = 1_i32
          COREWEBVIEW2_PERMISSION_KIND_CAMERA         = 2_i32
          COREWEBVIEW2_PERMISSION_KIND_GEOLOCATION    = 3_i32
          COREWEBVIEW2_PERMISSION_KIND_NOTIFICATIONS  = 4_i32
          COREWEBVIEW2_PERMISSION_KIND_CLIPBOARD_READ = 6_i32
          COREWEBVIEW2_PERMISSION_KIND_POINTER_LOCK   = 7_i32

          COREWEBVIEW2_PERMISSION_STATE_DEFAULT = 0_i32
          COREWEBVIEW2_PERMISSION_STATE_ALLOW   = 1_i32
          COREWEBVIEW2_PERMISSION_STATE_DENY    = 2_i32

          PERMISSION_REQUESTED_VTABLE = 53
        end

        alias NativeString = Pointer(Void)

        @@handler : Proc(String, String, String)?
        @@connected = false
        @@event_token : UInt64 = 0_u64

        def register(wv : ::CrystKit::Webview, &handler : String, String -> String) : Nil
          @@handler = handler
          connect_event(wv)
        end

        def register(wv : ::CrystKit::Webview, handler : Proc(String, String, String)) : Nil
          @@handler = handler
          connect_event(wv)
        end

        private def connect_event(wv : ::CrystKit::Webview) : Nil
          return if @@connected

          browser = wv.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER)
          return if browser.null?

          vtable_ptr = browser.as(Pointer(Pointer(Pointer(Void))))
          vtable = vtable_ptr.value
          fn_ptr = vtable[LibWebView2Perm::PERMISSION_REQUESTED_VTABLE]

          storage = uninitialized UInt64[2]
          storage[0] = fn_ptr.address
          storage[1] = 0_u64

          add_perm_fn = storage.to_unsafe.as(Pointer(Proc(Pointer(Void), Pointer(Void), Pointer(Void), Int32))).value

          cb = ->(_controller : Void*, args : Void*) : Int32 {
            handle_permission_event(args)
            0_i32
          }

          token = uninitialized UInt64
          hr = add_perm_fn.call(browser, cb.pointer.as(Void*), pointerof(token).as(Void*))

          if hr >= 0
            @@connected = true
            @@event_token = token
            Log.debug { "Permissions[Windows]: connected to PermissionRequested" }
          else
            Log.warn { "Permissions[Windows]: add_PermissionRequested failed HRESULT 0x#{hr.to_s(16)}" }
          end
        end

        private def handle_permission_event(args : Void*) : Nil
          return if args.null?

          args_vtable = args.as(Pointer(Pointer(Pointer(Void)))).value

          # ICoreWebView2PermissionRequestedEventArgs::get_PermissionKind
          get_kind_fn = make_wrapped_proc(args_vtable[3], Proc(Void*, Void*, Int32))
          kind_ptr = uninitialized Int32
          get_kind_fn.call(args, pointerof(kind_ptr).as(Void*))
          kind = kind_ptr

          # ICoreWebView2PermissionRequestedEventArgs::get_Uri
          get_uri_fn = make_wrapped_proc(args_vtable[4], Proc(Void*, Void*, Int32))
          uri_ptr = Pointer(Void).null
          get_uri_fn.call(args, pointerof(uri_ptr).as(Void*))

          origin = if uri_ptr.null?
                     "unknown://unknown"
                   else
                     str = ""
                     i = 0
                     ptr = uri_ptr.as(Pointer(UInt16))
                     while ptr[i] != 0
                       str += ptr[i].chr
                       i += 1
                     end
                     str
                   end

          perm_type = case kind
                      when LibWebView2Perm::COREWEBVIEW2_PERMISSION_KIND_MICROPHONE     then "microphone"
                      when LibWebView2Perm::COREWEBVIEW2_PERMISSION_KIND_CAMERA         then "camera"
                      when LibWebView2Perm::COREWEBVIEW2_PERMISSION_KIND_GEOLOCATION    then "geolocation"
                      when LibWebView2Perm::COREWEBVIEW2_PERMISSION_KIND_NOTIFICATIONS  then "notifications"
                      when LibWebView2Perm::COREWEBVIEW2_PERMISSION_KIND_CLIPBOARD_READ then "clipboard_read"
                      when LibWebView2Perm::COREWEBVIEW2_PERMISSION_KIND_POINTER_LOCK   then "pointer_lock"
                      else                                                                   "unknown"
                      end

          decision = if h = @@handler
                       case h.call(origin, perm_type).downcase
                       when "granted" then LibWebView2Perm::COREWEBVIEW2_PERMISSION_STATE_ALLOW
                       when "denied"  then LibWebView2Perm::COREWEBVIEW2_PERMISSION_STATE_DENY
                       else                LibWebView2Perm::COREWEBVIEW2_PERMISSION_STATE_DEFAULT
                       end
                     else
                       LibWebView2Perm::COREWEBVIEW2_PERMISSION_STATE_ALLOW
                     end

          # ICoreWebView2PermissionRequestedEventArgs::put_State
          put_state_fn = make_wrapped_proc(args_vtable[5], Proc(Void*, Int32, Void))
          put_state_fn.call(args, decision)
        end

        private def make_wrapped_proc(fn_ptr : Void*, type : T.class) : T forall T
          storage = uninitialized UInt64[2]
          storage[0] = fn_ptr.address
          storage[1] = 0_u64
          storage.to_unsafe.as(Pointer(T)).value
        end
      end
    end
  end
end
