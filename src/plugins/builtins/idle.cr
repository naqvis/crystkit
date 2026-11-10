require "../base"
require "../../features/idle_monitor"

module CrystKit
  module Plugins
    # System idle monitoring plugin.
    #
    # Registers IPC commands:
    #   system:idle_time — Get system idle time in seconds
    #   system:idle? — Check if the system is idle
    #   system:start_idle_monitor — Start monitoring for idle state changes
    #   system:stop_idle_monitor — Stop monitoring for idle state changes
    #
    # All commands are gated by the `system:read` capability.
    class Idle < Plugin::Base
      getter! monitor : Features::IdleMonitor

      @channel : Channel(Features::IdleMonitor::Change)?

      def identifier : String
        "idle"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(system.idle_time system.idle? system.start_idle_monitor system.stop_idle_monitor), "system:read")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(system:read),
          commands: %w(system.idle_time system.idle? system.start_idle_monitor system.stop_idle_monitor),
          events: %w(system:idle system:active),
          ipc: ipc,
        )
      end

      # `system.idle_time` returns the seconds since the last user input.
      # `system.idle?` returns whether the system is currently considered idle.
      # `system.start_idle_monitor` takes a *threshold* (seconds) and *interval*
      # (polling seconds) and starts emitting idle/active events to the
      # frontend.
      def initialize_plugin(context : Plugin::Context) : Nil
        @monitor = im = Features::IdleMonitor.new

        context.command "system.idle_time" do
          {"seconds" => im.idle_seconds}
        end

        context.command "system.idle?" do
          {"idle" => im.idle?}
        end

        context.command "system.start_idle_monitor", Int32, Int32 do |threshold, interval|
          @channel = channel = im.start_monitor(threshold.seconds, interval.seconds)
          Core::Fibers.spawn(name: "idle-emitter") do
            while change = channel.receive?
              event = change.idle? ? "system:idle" : "system:active"
              context.emit(event, JSON::Any.new({"seconds" => JSON::Any.new(change.seconds)}))
            end
          end
          nil
        end

        context.command "system.stop_idle_monitor" do
          im.stop_monitor
          @channel = nil
          nil
        end
      end

      def cleanup_plugin : Nil
        @monitor.try(&.stop_monitor)
        @channel = nil
      end
    end
  end
end
