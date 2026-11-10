require "./interface"
require "native_desktop"

{% if flag?(:darwin) %}
  require "./macos/objc_runtime"
{% end %}
{% if flag?(:linux) %}
  require "./linux/message_loop"
{% end %}
{% if flag?(:windows) %}
  require "./windows/message_loop"
  require "./windows/bind_workaround"
{% end %}

module CrystKit
  # Platform abstraction layer that bridges CrystKit to native OS capabilities.
  #
  # Each native capability (windowing, dialogs, clipboard, notifications,
  # etc.) is exposed as an abstract `*Backend` class. Platform-specific
  # implementations live in the `MacOS`, `Linux`, and `Windows` submodules.
  module Platform
    # Returns the name of the application currently holding foreground focus,
    # or an empty `String` when it cannot be determined.
    #
    # ```
    # if name = CrystKit::Platform.frontmost_app_name.presence
    #   puts "Focused app: #{name}"
    # end
    # ```
    def self.frontmost_app_name : String
      ::NativeDesktop.applications.foreground_name || ""
    rescue
      ""
    end
  end
end
