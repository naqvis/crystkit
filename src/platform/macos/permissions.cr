require "log"
require "./objc_runtime"
require "./init"

module CrystKit
  module Platform
    module MacOS
      module Permissions
        extend self

        @@handler : Proc(String, String, String)?
        @@delegate_installed = false

        # Link the C extension that swizzles WKWebView initWithFrame:configuration:
        # at runtime to enable media devices BEFORE the config is copied.
        # Crystal passes the .mm source to cc which compiles it as ObjC++.
        @[Link(ldflags: "#{__DIR__}/media_support.mm -framework WebKit -framework Foundation")]
        lib LibCrystKitMediaSupport
          fun crystkit_enable_media_devices : Void
          fun crystkit_set_media_handler(handler : Void*) : Void
          fun crystkit_install_media_delegate(wk : Void*) : Void
        end

        # Must be called BEFORE any WKWebView is created to install the swizzle.
        # Called from Permissions#initialize_plugin.
        def install_swizzle : Nil
          LibCrystKitMediaSupport.crystkit_enable_media_devices
        end

        def register(wv : ::CrystKit::Webview, &handler : String, String -> String) : Nil
          @@handler = handler
          install_delegate(wv)
        end

        def register(wv : ::CrystKit::Webview, handler : Proc(String, String, String)) : Nil
          @@handler = handler
          install_delegate(wv)
        end

        # After the WKWebView is created, install our WKUIDelegate that handles
        # media/geo permission requests and forwards everything else to the
        # original delegate (set by webview.o).
        private def install_delegate(wv : ::CrystKit::Webview) : Nil
          return if @@delegate_installed

          ObjCRuntime.with_autorelease_pool do
            # Set the C callback that the ObjC delegate calls
            handler_cb = ->(origin_cstr : LibC::Char*, type_cstr : LibC::Char*) : LibC::Int {
              origin = String.new(origin_cstr)
              type_str = String.new(type_cstr)
              if h = @@handler
                case h.call(origin, type_str).downcase
                when "granted" then return 1
                when "denied"  then return 2
                end
              end
              1
            }
            LibCrystKitMediaSupport.crystkit_set_media_handler(handler_cb.pointer)

            wk = wv.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER)
            if wk.null?
              Log.warn { "Cannot install media delegate: WKWebView is null" }
              return
            end

            LibCrystKitMediaSupport.crystkit_install_media_delegate(wk)
            @@delegate_installed = true
            Log.debug { "Permissions: installed media delegate" }
          end
        end
      end
    end
  end
end
