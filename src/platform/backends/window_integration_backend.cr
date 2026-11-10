require "log"
require "../../core/window_factory"

{% if flag?(:darwin) %}
  require "../macos/devtools"
  require "../macos/objc_runtime"
  require "../macos/permissions"
{% elsif flag?(:linux) %}
  require "../linux/devtools"
  require "../linux/permissions"
{% elsif flag?(:windows) %}
  require "../windows/devtools"
  require "../windows/permissions"
{% end %}

module CrystKit
  module Platform
    # Abstract interface for WebView permission handling and DevTools
    # integration.
    abstract class WindowIntegrationBackend
      # Performs any one-time platform preparation required before permission
      # prompts can be answered.
      abstract def prepare_permissions : Nil

      # Registers *handler` on *window* to decide permission requests.
      #
      # The handler receives the requesting *origin* and the permission *type*
      # and returns a permission decision string consumed by the platform.
      abstract def register_permissions(window : ::CrystKit::Webview, &handler : String, String -> String) : Nil

      # Enables the WebView developer extras for *window* so it can be
      # inspected.
      abstract def enable_devtools(window : ::CrystKit::Webview) : Nil

      # Opens the DevTools inspector for *native_window* docked according to
      # *dock_mode*.
      abstract def open_devtools(native_window : Pointer(Void), dock_mode : Int32) : Nil

      # Closes the DevTools inspector for *native_window*.
      abstract def close_devtools(native_window : Pointer(Void)) : Nil
    end

    # :nodoc:
    class CurrentWindowIntegrationBackend < WindowIntegrationBackend
      # :nodoc:
      Log = ::Log.for(self)

      # :nodoc:
      def prepare_permissions : Nil
        {% if flag?(:darwin) %}
          Current::Permissions.install_swizzle
        {% end %}
      end

      # :nodoc:
      def register_permissions(window : ::CrystKit::Webview, &handler : String, String -> String) : Nil
        Current::Permissions.register(window) { |origin, type| handler.call(origin, type) }
      end

      # :nodoc:
      def enable_devtools(window : ::CrystKit::Webview) : Nil
        {% if flag?(:darwin) %}
          ptr = window.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER)
          return if ptr.null?
          Current::ObjCRuntime.with_autorelease_pool do
            Current::ObjCRuntime.msg_bool(ptr, "setInspectable:", 1_i64)
            config = Current::ObjCRuntime.msg(ptr, "configuration")
            unless config.null?
              prefs = Current::ObjCRuntime.msg(config, "preferences")
              unless prefs.null?
                key = Current::ObjCRuntime.nsstring("developerExtrasEnabled")
                yes = Current::ObjCRuntime.msg(
                  Current::ObjCRuntime.get_class("NSNumber"),
                  "numberWithBool:",
                  Pointer(Void).new(1_u64)
                )
                Current::ObjCRuntime.msg(prefs, "setValue:forKey:", yes, key)
              end
            end
          end
        {% elsif flag?(:linux) %}
          ptr = window.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER)
          return if ptr.null?
          Current::DevTools::DevToolsSetup.enable_developer_extras(ptr)
        {% elsif flag?(:windows) %}
          Log.debug { "DevTools[Windows]: window created, inspector available via COM vtable" }
        {% end %}
      rescue ex
        Log.warn { "DevTools: window integration failed: #{ex.message}" }
      end

      # :nodoc:
      def open_devtools(native_window : Pointer(Void), dock_mode : Int32) : Nil
        Current::DevTools.open(native_window, dock_mode)
      end

      # :nodoc:
      def close_devtools(native_window : Pointer(Void)) : Nil
        Current::DevTools.close(native_window)
      end
    end
  end
end
