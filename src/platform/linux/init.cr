require "log"
require "./lib_gtk"

# Centralized initialization helpers for Linux platform modules.
# Manages common initialization tasks like GTK setup.

module CrystKit::Platform::Linux::Init
  extend self

  @@gtk_initialized = false

  # Ensure GTK is initialized.
  # Required for dialogs, notifications, tray icons, and other GTK features.
  # This is safe to call multiple times - GTK handles redundant initialization.
  def ensure_gtk : Nil
    return if @@gtk_initialized

    argc = 0
    LibGTK3.gtk_init(pointerof(argc), Pointer(Pointer(UInt8)).null)

    @@gtk_initialized = true
    Log.debug { "Init[Linux]: GTK initialized" }
  end

  # Check if GTK is initialized.
  def gtk_initialized? : Bool
    @@gtk_initialized
  end
end
