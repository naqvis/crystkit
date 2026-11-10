require "log"
require "./objc_runtime"
require "./init"

module CrystKit
  module Platform
    module MacOS
      module EnhancedWindow
        extend self

        NSFLOATING_WINDOW_LEVEL = 3_i64
        NSNORMAL_WINDOW_LEVEL   = 0_i64

        # Replaces the NSWindow's delegate so that `windowShouldClose:` hides
        # the window (orderOut:) and returns NO, keeping the webview run loop
        # alive.  This makes the close button act as "minimize to tray" for
        # tray-based apps on macOS.
        #
        # The original webview delegate is stored so that when the app truly
        # quits (via `terminate`) the original cleanup fires.
        @@close_hide_orig_delegate : Void* = Pointer(Void).null
        @@close_hide_own_delegate : Void* = Pointer(Void).null
        @@close_hide_callback : (Void*, Void*, Void* -> Int64)? = nil

        def enable_close_to_hide(native_window : Void*) : Nil
          return if native_window.null?
          ObjCRuntime.with_autorelease_pool do
            orig = ObjCRuntime.msg(native_window, "delegate")
            return if orig.null?
            @@close_hide_orig_delegate = orig

            # Register the proxy delegate class once
            if @@close_hide_own_delegate.null?
              ns_obj = ObjCRuntime.get_class("NSObject")
              cls = LibObjCRuntime.objc_allocateClassPair(ns_obj, "CloseHideDelegate", 0)
              if cls.null?
                cls = ObjCRuntime.get_class("CloseHideDelegate")
              end
              unless cls.null?
                cb = ->(_self_ : Void*, _cmd : Void*, w : Void*) : Int64 {
                  ew = CrystKit::Core::EnhancedWindow.lookup(w)
                  ew.try &.hide
                  0_i64
                }
                @@close_hide_callback = cb
                LibObjCRuntime.class_addMethod(
                  cls, LibObjC.sel_registerName("windowShouldClose:").as(Void*),
                  cb.pointer, "i@:@"
                )
                LibObjCRuntime.objc_registerClassPair(cls) unless cls.null?
                @@close_hide_own_delegate = ObjCRuntime.msg(
                  ObjCRuntime.msg(cls, "alloc"), "init"
                )
              end
            end

            del = @@close_hide_own_delegate
            unless del.null?
              ObjCRuntime.msg(native_window, "setDelegate:", del)
            end
          end
        end

        # Restore the original webview delegate so the next close actually
        # terminates the app (called before `terminate`).
        def disable_close_to_hide(native_window : Void*) : Nil
          return if native_window.null?
          orig = @@close_hide_orig_delegate
          unless orig.null?
            ObjCRuntime.msg(native_window, "setDelegate:", orig)
          end
        end

        @@close_prevent_delegate : Void* = Pointer(Void).null
        @@close_prevent_callback : (Void*, Void*, Void* -> Int64)? = nil

        def enable_close_prevention(native_window : Void*) : Nil
          return if native_window.null?
          ObjCRuntime.with_autorelease_pool do
            # Register ClosePreventDelegate class once
            if @@close_prevent_delegate.null?
              ns_obj = ObjCRuntime.get_class("NSObject")
              cls = LibObjCRuntime.objc_allocateClassPair(ns_obj, "ClosePreventDelegate", 0)
              if cls.null?
                cls = ObjCRuntime.get_class("ClosePreventDelegate")
              end
              unless cls.null?
                cb = ->(_self_ : Void*, _cmd : Void*, sender : Void*) : Int64 {
                  ew = CrystKit::Core::EnhancedWindow.lookup(sender)
                  if ew && !ew.handle_close_request
                    0_i64 # NO — prevent close
                  else
                    1_i64 # YES — allow close
                  end
                }
                @@close_prevent_callback = cb
                LibObjCRuntime.class_addMethod(
                  cls, LibObjC.sel_registerName("windowShouldClose:").as(Void*),
                  cb.pointer, "i@:@"
                )
                LibObjCRuntime.objc_registerClassPair(cls) unless cls.null?
                @@close_prevent_delegate = ObjCRuntime.msg(
                  ObjCRuntime.msg(cls, "alloc"), "init"
                )
              end
            end

            del = @@close_prevent_delegate
            unless del.null?
              ObjCRuntime.msg(native_window, "setDelegate:", del)
            end
          end
        end

        # Adjust the WKWebView's drawsBackground property to match
        # the window's transparency state.
        def set_webview_background(window : Void*, transparent : Bool) : Nil
          set_webview_draws_background(window, !transparent)
        end

        # No webview-specific focus adjustments needed on macOS.
        def after_focus(window : Void*) : Nil
        end

        private def set_webview_draws_background(window : Void*, draws : Bool) : Nil
          content_view = ObjCRuntime.msg(window, "contentView")
          return if content_view.null?
          wkwebview_class = ObjCRuntime.get_class("WKWebView")
          return if wkwebview_class.null?
          bool_class = ObjCRuntime.get_class("NSNumber")
          bool_val = ObjCRuntime.msg_bool(bool_class, "numberWithBool:", draws ? 1_i64 : 0_i64)
          return if bool_val.null?
          key = ObjCRuntime.nsstring("drawsBackground")
          if !ObjCRuntime.msg(content_view, "isKindOfClass:", wkwebview_class).null?
            ObjCRuntime.msg(content_view, "setValue:forKey:", bool_val, key)
          end
          subviews = ObjCRuntime.msg(content_view, "subviews")
          return if subviews.null?
          count = ObjCRuntime.msg_long(subviews, "count")
          count.times do |i|
            subview = ObjCRuntime.msg_object_at(subviews, "objectAtIndex:", i.to_u64)
            next if subview.null?
            if !ObjCRuntime.msg(subview, "isKindOfClass:", wkwebview_class).null?
              ObjCRuntime.msg(subview, "setValue:forKey:", bool_val, key)
            end
          end
        end
      end
    end
  end
end
