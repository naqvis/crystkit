# Re-exports native_desktop's Win32 common declarations into
# the CrystKit module namespace so existing callers need no changes.
# This avoids duplicating the ~300 lines of FFI bindings.
require "native_desktop/platform/windows/win32_common"

module CrystKit
  module Platform
    module Windows
      include NativeDesktop::Platform::Windows

      LibOLE = NativeDesktop::Platform::Windows::LibOLE
    end
  end
end
