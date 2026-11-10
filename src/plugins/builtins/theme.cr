require "../base"
require "../../features/system_theme"

module CrystKit
  module Plugins
    # Builtin plugin that monitors the operating-system theme (light/dark) and
    # notifies the frontend when it changes.
    #
    # `theme.current` returns the current theme synchronously;
    # `theme.start_monitor` polls the backend on an interval in a background
    # fiber and emits `theme.changed` whenever the theme flips.
    # `theme.stop_monitor` stops event delivery.
    #
    # Registers IPC commands:
    #   theme:current — Get the current system theme
    #   theme:start_monitor — Start monitoring system theme changes
    #   theme:stop_monitor — Stop monitoring system theme changes
    #
    # Emits events: `theme.changed`
    #
    # Required capabilities: `theme:read`, `theme:manage`
    #
    # `theme.start_monitor` takes the poll interval in seconds. The `theme.changed`
    # payload is `{"theme" => "light" | "dark"}`.
    #
    # ```
    # app.plugin(CrystKit::Plugins::Theme.new)
    # ```
    class Theme < Plugin::Base
      # The system-theme feature, lazily initialized during `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! theme : Features::SystemTheme

      # The active event stream. Replacing or stopping it closes the previous
      # stream so its emitter fiber exits.
      @channel : Channel(String)? = nil

      # Returns the unique plugin identifier `"theme"`.
      def identifier : String
        "theme"
      end

      # Returns the metadata contract splitting theme access into a read
      # capability and a management capability.
      #
      # `theme.current` requires only `theme:read`; `theme.start_monitor` and
      # `theme.stop_monitor` require `theme:manage`.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require("theme.current", "theme:read")
          .require(%w(theme.start_monitor theme.stop_monitor), "theme:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(theme:read theme:manage),
          commands: %w(theme.current theme.start_monitor theme.stop_monitor),
          events: %w(theme.changed),
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # `theme.current` returns `{"theme" => "light" | "dark"}` (downcased).
      # `theme.start_monitor` spawns a background fiber that emits
      # `theme.changed` for each theme change. `theme.stop_monitor` closes the
      # stream and stops the native monitor.
      def initialize_plugin(context : Plugin::Context) : Nil
        @theme = th = Features::SystemTheme.new

        context.command "theme.current" do
          {"theme" => th.current.to_s.downcase}
        end

        context.command "theme.start_monitor", Int32 do |interval_seconds|
          @channel = ch = th.start_monitor(interval_seconds.seconds)
          Core::Fibers.spawn(name: "theme-emitter") do
            while new_theme = ch.receive?
              context.emit("theme.changed", context.app.coerce_to_json({"theme" => new_theme}))
            end
          end
          nil
        end

        context.command "theme.stop_monitor" do
          th.stop_monitor
          @channel = nil
          nil
        end
      end

      def cleanup_plugin : Nil
        @theme.try(&.stop_monitor)
        @channel = nil
      end
    end
  end
end
