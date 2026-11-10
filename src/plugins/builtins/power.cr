require "../base"
require "../../features/power_monitor"

module CrystKit
  module Plugins
    # Builtin plugin that exposes battery and power-state information to the
    # frontend.
    #
    # `start_monitoring` emits `power:battery_changed` events when battery
    # state changes.
    #
    # Registers IPC commands:
    #   power:battery_info — Get battery charge info
    #   power:on_battery — Check if running on battery power
    #   power:start_monitoring — Start power state monitoring
    #   power:stop_monitoring — Stop power state monitoring
    #
    # Required capability: `power:read`
    class Power < Plugin::Base
      # The `Features::PowerMonitor`, lazily initialized during
      # `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! monitor : Features::PowerMonitor

      @channel : Channel(Features::PowerMonitor::BatteryInfo)?

      # Returns the unique plugin identifier `"power"`.
      def identifier : String
        "power"
      end

      # Returns the metadata contract binding all four commands to the
      # `power:read` capability using capability-only `require` policies.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(power.battery_info power.on_battery power.start_monitoring power.stop_monitoring), "power:read")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(power:read),
          commands: %w(power.battery_info power.on_battery power.start_monitoring power.stop_monitoring),
          events: %w(power:battery_changed),
          ipc: ipc,
        )
      end

      # Registers the power IPC commands.
      #
      # `power.battery_info` returns `{"charging", "level", "time_remaining"}`
      # when a battery is present, or `nil` when the device has no battery
      # (e.g. a desktop). `power.on_battery` returns `{"on_battery"}` which
      # is true only when a battery exists and is discharging. `power.start_monitoring`
      # spawns a background fiber that emits `power:battery_changed` events
      # whenever the current `{"charging", "level"}` snapshot changes.
      def initialize_plugin(context : Plugin::Context) : Nil
        @monitor = pm = Features::PowerMonitor.new

        context.command "power.battery_info" do
          info = pm.battery_info
          if info
            {"charging" => info.charging?, "level" => info.level, "time_remaining" => info.time_remaining}
          else
            nil
          end
        end

        context.command "power.on_battery" do
          {"on_battery" => pm.on_battery?}
        end

        context.command "power.start_monitoring" do
          @channel = channel = pm.start_monitor
          Core::Fibers.spawn(name: "power-emitter") do
            while info = channel.receive?
              context.emit("power:battery_changed", JSON::Any.new({
                "charging" => JSON::Any.new(info.charging?),
                "level"    => JSON::Any.new(info.level),
              }))
            end
          end
          nil
        end

        context.command "power.stop_monitoring" do
          pm.stop_monitor
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
