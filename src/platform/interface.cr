require "../core/errors"
require "./icon_source"

{% if flag?(:darwin) %}
  require "file_utils"
{% end %}

module CrystKit
  module Platform
    # A flattened representation of a tray menu item passed to the native
    # backend.
    alias TrayMenuEntry = NamedTuple(
      id: String,
      label: String,
      type: Int32,         # Features::TrayMenuItemType ordinal (0 normal, 1 checkbox, 2 radio, 3 separator)
      enabled: Int32,      # 1 interactive, 0 greyed out
      checked: Int32,      # 1 ticked (checkbox/radio), 0 otherwise
      parent_id: String,   # parent item id for submenu nesting, empty for top-level
      accelerator: String? # keyboard shortcut display string (e.g. "Cmd+Shift+V"), nil for none
)

    # Platform type alias for the compile-time target platform.
    #
    # Resolves to the `MacOS`, `Linux`, or `Windows` submodule matching the
    # compile target. Compiling for an unsupported target raises at
    # compile time.
    {% if flag?(:darwin) %}
      alias Current = MacOS
    {% elsif flag?(:linux) %}
      alias Current = Linux
    {% elsif flag?(:windows) %}
      alias Current = Windows
    {% else %}
      {% raise "Unsupported platform" %}
    {% end %}
  end
end
