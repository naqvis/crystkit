require "../base"
require "../../features/autostart"

module CrystKit
  module Plugins
    # Plugin that manages OS-level autostart registration so the application
    # launches on user login.
    #
    # Registers IPC commands:
    #   autostart.enable — Enable autostart with optional args, minimized, and delay
    #   autostart.disable — Disable autostart
    #   autostart.enabled — Check if autostart is enabled
    #
    # All commands require the `autostart:manage` capability.
    #
    # ```
    # app.plugin(CrystKit::Plugins::Autostart.new)
    # ```
    class Autostart < Plugin::Base
      getter! autostart : Features::Autostart

      def identifier : String
        "autostart"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(autostart.enable autostart.disable autostart.enabled), "autostart:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(autostart:manage),
          commands: %w(autostart.enable autostart.disable autostart.enabled),
          ipc: ipc,
        )
      end

      # `autostart.enable` accepts a JSON object with optional `args` (launch
      # arguments), `minimized` (start hidden), and `delay` (seconds to wait
      # before launching).
      def initialize_plugin(context : Plugin::Context) : Nil
        app_name = context.app.config.name
        app_path_str = ::Process.executable_path || ""
        @autostart = auto = Features::Autostart.new(app_name, Path[app_path_str])

        context.command "autostart.enable", JSON::Any do |opts|
          args = opts["args"]?.try(&.as_a.map(&.as_s)) || [] of String
          minimized = opts["minimized"]?.try(&.as_bool) || false
          delay = opts["delay"]?.try(&.as_i) || 0

          options = Features::AutostartOptions.new(args, minimized, delay.seconds)
          auto.enable(options)
        end

        context.command "autostart.disable" do
          auto.disable
        end

        context.command "autostart.enabled" do
          auto.enabled?
        end
      end
    end
  end
end
