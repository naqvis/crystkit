require "log"
require "./lib_glib"

module CrystKit
  module Platform
    module Linux
      module MessageLoop
        # How often (ms) to yield to Crystal's event loop.
        # 16ms ≈ 60 fps — keeps the server fiber responsive while
        # leaving plenty of time between timer fires for GTK to
        # poll real I/O events (close button, keyboard, …).
        POLL_MS = 16_u32

        def self.start(window : Void*) : Nil
          Log.debug { "MessageLoop[Linux]: starting cooperative GTK message pump" }

          # Install a GLib timer that fires every POLL_MS and yields
          # to Crystal's event loop.  Between timer fires GTK can
          # block on poll(2) for real I/O events (close, keyboard,
          # etc.) because no always-ready idle source is in the way.
          source_id = LibGLib.g_timeout_add(
            POLL_MS,
            ->(_data : Void*) {
              Fiber.yield
              1_u32
            }.pointer,
            Pointer(Void).null
          )

          # Use the real blocking webview_run — it handles window close
          # (destroy signal → on_window_destroyed → terminate) and
          # terminate (internal stop flag) correctly, exiting the loop
          # when either occurs.
          ::Webview::LibWebView.run(window)

          if source_id != 0
            LibGLib.g_source_remove(source_id)
          end
        rescue ex
          Log.debug { "MessageLoop[Linux]: pump exited: #{ex.message}" }
        end
      end
    end
  end
end

CrystKit::Core::MessageLoopHook.set(->(w : Void*) {
  CrystKit::Platform::Linux::MessageLoop.start(w)
})
