require "log"
require "./objc_runtime"

module CrystKit
  module Platform
    module MacOS
      module Panel
        extend self

        NS_NONACTIVATING_PANEL_MASK =  128_u64
        NS_HUD_WINDOW_MASK          = 8192_u64
        NS_UTILITY_WINDOW_MASK      =   16_u64

        NSPOPUP_WINDOW_LEVEL        =  101_i64
        NSSCREEN_SAVER_WINDOW_LEVEL = 1000_i64
        NSSTATUS_WINDOW_LEVEL       =   25_i64
        NSMAIN_MENU_WINDOW_LEVEL    =   24_i64
        NSDOCK_WINDOW_LEVEL         =   22_i64

        NSWindowCollectionBehaviorDefault             =   0_i64
        NSWindowCollectionBehaviorCanJoinAllSpaces    =   1_i64
        NSWindowCollectionBehaviorMoveToActiveSpace   =   2_i64
        NSWindowCollectionBehaviorManaged             =   4_i64
        NSWindowCollectionBehaviorTransient           =   8_i64
        NSWindowCollectionBehaviorStationary          =  16_i64
        NSWindowCollectionBehaviorParticipatesInCycle =  32_i64
        NSWindowCollectionBehaviorIgnoresCycle        =  64_i64
        NSWindowCollectionBehaviorFullScreenPrimary   = 128_i64
        NSWindowCollectionBehaviorFullScreenAuxiliary = 256_i64
        NSWindowCollectionBehaviorFullScreenNone      = 512_i64

        @@panels = {} of String => Void*
        @@panel_class : Void* = Pointer(Void).null
        @@original_classes = {} of String => Void*
        @@mouse_inside = {} of String => Bool
        @@nswindow_send_imp : Void* = Pointer(Void).null
        @@mouse_down_location = {} of UInt64 => LibObjC::NSPoint
        @@drag_modes = {} of UInt64 => Symbol

        private def ensure_panel_class : Void*
          return @@panel_class unless @@panel_class.null?
          nspanel_cls = ObjCRuntime.get_class("NSPanel")
          cls = LibObjCRuntime.objc_allocateClassPair(nspanel_cls, "CrystKitPanel", 0)
          if cls.null?
            Log.error { "NSPanel[macOS]: Failed to allocate CrystKitPanel class" }
            return Pointer(Void).null
          end

          if @@nswindow_send_imp.null?
            @@nswindow_send_imp = LibObjCRuntime.class_getMethodImplementation(
              ObjCRuntime.get_class("NSWindow"),
              LibObjC.sel_registerName("sendEvent:").as(Void*),
            )
          end

          cb_key = ->(_self : Void*, _cmd : Void*) : Int8 { 1_i8 }
          LibObjCRuntime.class_addMethod(
            cls, LibObjC.sel_registerName("canBecomeKeyWindow").as(Void*),
            cb_key.pointer, "c@:"
          )
          cb_floating = ->(_self : Void*, _cmd : Void*) : Int8 { 1_i8 }
          LibObjCRuntime.class_addMethod(
            cls, LibObjC.sel_registerName("isFloatingPanel").as(Void*),
            cb_floating.pointer, "c@:"
          )
          cb_main = ->(_self : Void*, _cmd : Void*) : Int8 { 1_i8 }
          LibObjCRuntime.class_addMethod(
            cls, LibObjC.sel_registerName("canBecomeMainWindow").as(Void*),
            cb_main.pointer, "c@:"
          )

          cb_send = ->(_self : Void*, _cmd : Void*, _event : Void*) {
            drag_mode = @@drag_modes[_self.address]?
            if drag_mode == :background
              event_type = ObjCRuntime.msg_long(_event, "type")
              case event_type
              when 1_i64 # NSLeftMouseDown
                @@mouse_down_location[_self.address] = ObjCRuntime.msg_point(_event, "locationInWindow")
                fn = ObjCRuntime::MsgSendVoidId.new(@@nswindow_send_imp, Pointer(Void).null)
                fn.call(_self.as(LibObjC::Id), LibObjC.sel_registerName("sendEvent:"), _event.as(LibObjC::Id))
              when 6_i64, 7_i64 # NSLeftMouseDragged, NSRightMouseDragged
                if initial = @@mouse_down_location[_self.address]?
                  current = ObjCRuntime.msg_point(_event, "locationInWindow")
                  frame = ObjCRuntime.msg_rect(_self, "frame")
                  ObjCRuntime.msg_void(_self, "setFrameOrigin:", frame.x + current.x - initial.x, frame.y + current.y - initial.y)
                end
              else
                fn = ObjCRuntime::MsgSendVoidId.new(@@nswindow_send_imp, Pointer(Void).null)
                fn.call(_self.as(LibObjC::Id), LibObjC.sel_registerName("sendEvent:"), _event.as(LibObjC::Id))
              end
            else
              fn = ObjCRuntime::MsgSendVoidId.new(@@nswindow_send_imp, Pointer(Void).null)
              fn.call(_self.as(LibObjC::Id), LibObjC.sel_registerName("sendEvent:"), _event.as(LibObjC::Id))
            end
          }
          LibObjCRuntime.class_addMethod(
            cls, LibObjC.sel_registerName("sendEvent:").as(Void*),
            cb_send.pointer, "v@:@"
          )

          cb_hover = ->(_self : Void*, _cmd : Void*, _sender : Void*) {
            mouse_pt = ObjCRuntime.msg_point(ObjCRuntime.get_class("NSEvent"), "mouseLocation")
            panel_frame = ObjCRuntime.msg_rect(_self, "frame")

            inside = mouse_pt.x >= panel_frame.x &&
                     mouse_pt.x <= panel_frame.x + panel_frame.w &&
                     mouse_pt.y >= panel_frame.y &&
                     mouse_pt.y <= panel_frame.y + panel_frame.h

            label = nil
            @@panels.each do |k, v|
              if v == _self
                label = k
                break
              end
            end

            if l = label
              prev = @@mouse_inside.fetch(l, false)

              if inside && !prev
                ns_app = ObjCRuntime.msg(ObjCRuntime.get_class("NSApplication"), "sharedApplication")
                ObjCRuntime.msg_int(ns_app, "activateIgnoringOtherApps:", 1_i64) unless ns_app.null?
                ObjCRuntime.msg_void(_self, "makeKeyWindow")
                cv = ObjCRuntime.msg(_self, "contentView")
                unless cv.null?
                  js = ObjCRuntime.nsstring("var ta=document.querySelector('textarea');if(ta)ta.focus();")
                  ObjCRuntime.msg_void(cv, "evaluateJavaScript:completionHandler:", js, Pointer(Void).null)
                end
              elsif !inside && prev
                cv = ObjCRuntime.msg(_self, "contentView")
                unless cv.null?
                  js = ObjCRuntime.nsstring("document.activeElement&&document.activeElement.blur()")
                  ObjCRuntime.msg_void(cv, "evaluateJavaScript:completionHandler:", js, Pointer(Void).null)
                end
              end

              @@mouse_inside[l] = inside
            end

            hover_sel = LibObjC.sel_registerName("hoverCheck:").as(Void*)
            ObjCRuntime.msg_void(_self, "performSelector:withObject:afterDelay:", hover_sel, Pointer(Void).null, 0.05)
          }
          LibObjCRuntime.class_addMethod(
            cls, LibObjC.sel_registerName("hoverCheck:").as(Void*),
            cb_hover.pointer, "v@:@"
          )
          LibObjCRuntime.objc_registerClassPair(cls)
          @@panel_class = cls
          cls
        end

        def ns_window_to_panel(ns_window : Void*, label : String) : Void*
          return Pointer(Void).null if ns_window.null?
          panel_cls = ensure_panel_class
          return Pointer(Void).null if panel_cls.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_uint(ns_window, "setStyleMask:", NS_NONACTIVATING_PANEL_MASK)
            level = EnhancedWindow::NSFLOATING_WINDOW_LEVEL
            ObjCRuntime.msg_int(ns_window, "setLevel:", level)
            ObjCRuntime.msg_int(ns_window, "setHidesOnDeactivate:", 0_i64)
            @@original_classes[label] = LibObjCRuntime.object_getClass(ns_window)
            LibObjCRuntime.object_setClass(ns_window, panel_cls)
            @@panels[label] = ns_window
            ns_window
          end
        end

        def panel_to_window(label : String) : Nil
          panel = @@panels[label]?
          return if panel.nil? || panel.null?
          cancel_hover(panel)
          orig_cls = @@original_classes[label]?
          if orig_cls && !orig_cls.null?
            LibObjCRuntime.object_setClass(panel, orig_cls)
          end
          @@panels.delete(label)
          @@original_classes.delete(label)
          @@mouse_inside.delete(label)
        end

        def register_panel(label : String, panel : Void*) : Nil
          @@panels[label] = panel unless panel.null?
        end

        def get_panel_handle(label : String) : Void*
          @@panels[label]? || Pointer(Void).null
        end

        def unregister_panel(label : String) : Nil
          if panel = @@panels[label]?
            cancel_hover(panel)
          end
          @@panels.delete(label)
          @@original_classes.delete(label)
          @@mouse_inside.delete(label)
        end

        def panel_show(panel : Void*) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_void(panel, "orderFrontRegardless")
          end
        end

        def panel_hide(panel : Void*) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_void(panel, "orderOut:", Pointer(Void).null)
          end
        end

        def panel_show_and_make_key(panel : Void*) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            content_view = ObjCRuntime.msg(panel, "contentView")
            unless content_view.null?
              ObjCRuntime.msg_void(panel, "makeFirstResponder:", content_view)
            end
            ObjCRuntime.msg_void(panel, "orderFrontRegardless")
            ObjCRuntime.msg_void(panel, "makeKeyWindow")
          end
        end

        def panel_order_front_regardless(panel : Void*) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_void(panel, "orderFrontRegardless")
          end
        end

        def panel_set_level(panel : Void*, level : Int64) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_int(panel, "setLevel:", level)
          end
        end

        def panel_set_floating(panel : Void*, floating : Bool) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_int(panel, "setFloatingPanel:", floating ? 1_i64 : 0_i64)
          end
        end

        def panel_set_hides_on_deactivate(panel : Void*, value : Bool) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_int(panel, "setHidesOnDeactivate:", value ? 1_i64 : 0_i64)
          end
        end

        def panel_set_alpha(panel : Void*, alpha : Float64) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_float(panel, "setAlphaValue:", alpha.clamp(0.0, 1.0))
          end
        end

        def panel_set_transparent(panel : Void*, transparent : Bool) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            if transparent
              ObjCRuntime.msg_int(panel, "setOpaque:", 0_i64)
              clear_color = ObjCRuntime.msg(ObjCRuntime.get_class("NSColor"), "clearColor")
              ObjCRuntime.msg_void(panel, "setBackgroundColor:", clear_color) unless clear_color.null?
            else
              ObjCRuntime.msg_int(panel, "setOpaque:", 1_i64)
              bg_color = ObjCRuntime.msg(ObjCRuntime.get_class("NSColor"), "windowBackgroundColor")
              ObjCRuntime.msg_void(panel, "setBackgroundColor:", bg_color) unless bg_color.null?
            end
          end
        end

        def panel_set_ignores_mouse_events(panel : Void*, value : Bool) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_int(panel, "setIgnoresMouseEvents:", value ? 1_i64 : 0_i64)
          end
        end

        def panel_set_style_mask(panel : Void*, mask : UInt64) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_uint(panel, "setStyleMask:", mask)
          end
        end

        def panel_set_titlebar_appears_transparent(panel : Void*, value : Bool) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_int(panel, "setTitlebarAppearsTransparent:", value ? 1_i64 : 0_i64)
          end
        end

        def panel_set_movable_by_background(panel : Void*, value : Bool) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_int(panel, "setMovableByWindowBackground:", value ? 1_i64 : 0_i64)
          end
          @@drag_modes[panel.address] = value ? :background : :css_region
        end

        def panel_set_drag_mode(panel : Void*, mode : Symbol) : Nil
          return if panel.null?
          @@drag_modes[panel.address] = mode
        end

        def panel_set_has_shadow(panel : Void*, value : Bool) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_int(panel, "setHasShadow:", value ? 1_i64 : 0_i64)
          end
        end

        def panel_set_collection_behavior(panel : Void*, behavior : Int64) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_int(panel, "setCollectionBehavior:", behavior)
          end
        end

        def panel_set_works_when_modal(panel : Void*, value : Bool) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_int(panel, "setWorksWhenModal:", value ? 1_i64 : 0_i64)
          end
        end

        def panel_set_accepts_mouse_moved_events(panel : Void*, value : Bool) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_int(panel, "setAcceptsMouseMovedEvents:", value ? 1_i64 : 0_i64)
          end
        end

        def panel_set_corner_radius(panel : Void*, radius : Float64) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            content_view = ObjCRuntime.msg(panel, "contentView")
            return if content_view.null?
            ObjCRuntime.msg_int(content_view, "setWantsLayer:", 1_i64)
            layer = ObjCRuntime.msg(content_view, "layer")
            unless layer.null?
              ObjCRuntime.msg_float(layer, "setCornerRadius:", radius)
            end
          end
        end

        def panel_make_key(panel : Void*) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_void(panel, "makeKeyWindow")
          end
        end

        def panel_resign_key(panel : Void*) : Nil
          return if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_void(panel, "resignKeyWindow")
          end
        end

        def panel_is_visible(panel : Void*) : Bool
          return false if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_long(panel, "isVisible") != 0
          end
        end

        def panel_is_floating(panel : Void*) : Bool
          return false if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_long(panel, "isFloatingPanel") != 0
          end
        end

        def panel_can_become_key(panel : Void*) : Bool
          return false if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_long(panel, "canBecomeKeyWindow") != 0
          end
        end

        def panel_hides_on_deactivate(panel : Void*) : Bool
          return false if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_long(panel, "hidesOnDeactivate") != 0
          end
        end

        def panel_style_mask(panel : Void*) : UInt64
          return 0_u64 if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_long(panel, "styleMask").to_u64!
          end
        end

        def panel_level(panel : Void*) : Int64
          return 0_i64 if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_long(panel, "level")
          end
        end

        def panel_alpha_value(panel : Void*) : Float64
          return 0.0 if panel.null?
          ObjCRuntime.with_autorelease_pool do
            ObjCRuntime.msg_double(panel, "alphaValue")
          end
        end

        def panel_add_tracking_area(panel : Void*, label : String = "") : Nil
          return if panel.null?
          @@panels[label] = panel
          @@mouse_inside[label] = false
          hover_sel = LibObjC.sel_registerName("hoverCheck:").as(Void*)
          ObjCRuntime.msg_void(panel, "performSelector:withObject:afterDelay:", hover_sel, Pointer(Void).null, 0.05)
        end

        def panel_blur_webview(panel : Void*) : Nil
          return if panel.null?
          cv = ObjCRuntime.msg(panel, "contentView")
          unless cv.null?
            js = ObjCRuntime.nsstring("document.activeElement&&document.activeElement.blur()")
            ObjCRuntime.msg_void(cv, "evaluateJavaScript:completionHandler:", js, Pointer(Void).null)
          end
        end

        def panel_focus_webview(panel : Void*) : Nil
          return if panel.null?
          cv = ObjCRuntime.msg(panel, "contentView")
          unless cv.null?
            js = ObjCRuntime.nsstring("var ta=document.querySelector('textarea');if(ta)ta.focus();")
            ObjCRuntime.msg_void(cv, "evaluateJavaScript:completionHandler:", js, Pointer(Void).null)
          end
        end

        def panel_add_hover_check(panel : Void*, label : String = "") : Nil
          return if panel.null?
          @@panels[label] = panel
          @@mouse_inside[label] = false
          hover_sel = LibObjC.sel_registerName("hoverCheck:").as(Void*)
          ObjCRuntime.msg_void(panel, "performSelector:withObject:afterDelay:", hover_sel, Pointer(Void).null, 0.05)
        end

        # Cancel all pending delayed performs (hoverCheck: etc.) on the panel
        # so they don't fire after the panel is destroyed.
        def cancel_hover(panel : Void*) : Nil
          return if panel.null?
          ns_object = ObjCRuntime.get_class("NSObject")
          ObjCRuntime.msg_void(ns_object, "cancelPreviousPerformRequestsWithTarget:", panel)
        end
      end
    end
  end
end
