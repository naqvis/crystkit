require "log"
require "./objc_runtime"

# Centralized initialization helpers for macOS platform modules.
# Manages common initialization tasks like NSApplication setup.

module CrystKit::Platform::MacOS::Init
  extend self

  @@app_initialized = false

  # Ensure NSApplication is initialized and activated.
  # Required for dialogs, notifications, and other AppKit features.
  # Returns true if successful, false otherwise.
  def ensure_app : Bool
    return true if @@app_initialized

    app = ObjCRuntime.msg(ObjCRuntime.get_class("NSApplication"), "sharedApplication")
    return false if app.null?

    # NSApplicationActivationPolicyRegular = 0
    # NSApplicationActivationPolicyAccessory = 1
    # NSApplicationActivationPolicyProhibited = 2
    # Use Accessory (1) for background apps, Regular (0) for GUI apps
    ObjCRuntime.msg_bool(app, "setActivationPolicy:", 0_i64)

    @@app_initialized = true
    Log.debug { "Init[macOS]: NSApplication initialized" }
    true
  end

  # Check if NSApplication is initialized.
  def app_initialized? : Bool
    @@app_initialized
  end
end
