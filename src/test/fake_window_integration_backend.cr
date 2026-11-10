require "../platform/backends/window_integration_backend"

module CrystKit
  module Test
    # Recording `WindowIntegrationBackend` for specs.
    #
    # Captures DevTools open/close calls (and the dock mode used) so
    # `DevTools` open/close state transitions and handlers can be asserted
    # without a native webview.
    class FakeWindowIntegrationBackend < Platform::WindowIntegrationBackend
      getter? prepared : Bool = false
      getter? opened : Bool = false
      getter? closed : Bool = false
      getter last_dock_mode : Int32?

      def prepare_permissions : Nil
        @prepared = true
      end

      def register_permissions(window : Webview, &_handler : String, String -> String) : Nil
      end

      def enable_devtools(window : Webview) : Nil
      end

      def open_devtools(native_window : Pointer(Void), dock_mode : Int32) : Nil
        @opened = true
        @last_dock_mode = dock_mode
      end

      def close_devtools(native_window : Pointer(Void)) : Nil
        @closed = true
      end
    end
  end
end
