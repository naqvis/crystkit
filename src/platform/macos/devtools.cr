require "log"
require "../../core/errors"
require "./objc_runtime"
require "./init"

module CrystKit
  module Platform
    module MacOS
      module DevTools
        extend self

        DOCK_UNDOCKED = 0
        DOCK_BOTTOM   = 1
        DOCK_RIGHT    = 2
        DOCK_LEFT     = 3

        def open(native_widget : Pointer(Void), dock_mode : Int32) : Nil
          return if native_widget.null?
          ObjCRuntime.with_autorelease_pool do
            inspector = ObjCRuntime.msg(native_widget, "_inspector")
            return if inspector.null?
            # Detach first so the inspector opens in its own window instead of
            # docking inside the app window (which breaks the title bar buttons).
            ObjCRuntime.msg(inspector, "detach")
            ObjCRuntime.msg(inspector, "show")
            Log.info { "DevTools[macOS]: inspector opened (detached)" }
          end
        rescue ex
          Log.error { "DevTools[macOS]: open failed: #{ex.class} — #{ex.message.inspect}" }
        end

        def close(native_widget : Pointer(Void)) : Nil
          return if native_widget.null?
          ObjCRuntime.with_autorelease_pool do
            inspector = ObjCRuntime.msg(native_widget, "_inspector")
            return if inspector.null?
            ObjCRuntime.msg(inspector, "close")
            Log.info { "DevTools[macOS]: inspector closed" }
          end
        rescue ex
          Log.error { "DevTools[macOS]: close failed: #{ex.class} — #{ex.message.inspect}" }
        end
      end
    end
  end
end
