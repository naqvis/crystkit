require "log"
require "./win32_common"

# Centralized initialization helpers for Windows platform modules.
# Manages common initialization tasks like message queues and COM.

module CrystKit::Platform::Windows::Init
  extend self

  @@message_queue_initialized = false
  @@com_initialized = false

  # Ensure the calling thread has a message queue.
  # Required for clipboard operations and some other Win32 APIs.
  def ensure_message_queue : Nil
    return if @@message_queue_initialized

    msg = uninitialized UInt64[6]
    LibUser32.PeekMessageW(msg.to_unsafe.as(Void*), Pointer(Void).null, 0, 0, 0)
    @@message_queue_initialized = true
  end

  # Initialize COM for the current thread (apartment-threaded).
  # Returns true if successful or already initialized.
  def ensure_com : Bool
    return true if @@com_initialized

    # COINIT_APARTMENTTHREADED = 0x2
    result = LibOLE.CoInitializeEx(Pointer(Void).null, 0x2_u32)

    # S_OK = 0, S_FALSE = 1 (already initialized)
    if result == 0 || result == 1
      @@com_initialized = true
      true
    else
      Log.warn { "Init[Windows]: COM initialization failed with code #{result}" }
      false
    end
  end

  # Uninitialize COM for the current thread.
  # Should be called when the thread is done using COM.
  def uninit_com : Nil
    return unless @@com_initialized
    LibOLE.CoUninitialize
    @@com_initialized = false
  end
end
