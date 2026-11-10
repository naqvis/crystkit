require "log"
require "./win32_common"

module CrystKit
  module Platform
    module Windows
      module MessageLoop
        extend self

        def self.start(window : Void*) : Nil
          Log.debug { "MessageLoop[Windows]: starting cooperative message pump" }

          msg = Bytes.new(48, 0_u8) # MSG structure (48 bytes on Win64)
          loop do
            has_msg = LibUser32.PeekMessageW(
              msg.to_unsafe, Pointer(Void).null, 0_u32, 0_u32, 0_u32,
            )
            if has_msg != 0
              ret = LibUser32.GetMessageW(
                msg.to_unsafe, Pointer(Void).null, 0_u32, 0_u32,
              )
              break if ret == 0 # WM_QUIT → exit

              # Let menu/keyboard accelerators take precedence. If the message
              # was consumed as an accelerator, skip normal translation.
              translated = ::NativeDesktop::Runtime.process_event(msg.to_unsafe.as(Void*)) ? 1 : 0

              if translated == 0
                LibUser32.TranslateMessage(msg.to_unsafe)
                LibUser32.DispatchMessageW(msg.to_unsafe)
              end
            else
              sleep 0.seconds
            end
          end
        end
      end
    end
  end
end

# ── Registration ──────────────────────────────────────────────────────
# Self-register as the CrystKit message-loop hook.

CrystKit::Core::MessageLoopHook.set(->(w : Void*) {
  CrystKit::Platform::Windows::MessageLoop.start(w)
})
