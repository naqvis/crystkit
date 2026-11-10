require "../base"
require "../../features/hardware"

module CrystKit
  module Plugins
    # Plugin exposing hardware device discovery and lifecycle management to the
    # frontend.
    #
    # Registers IPC commands:
    #   hardware.available — Query whether a device type is available
    #   hardware.list — List devices of a type
    #   hardware.enumerate — Explicitly enumerate devices of a type
    #   hardware.forget — Forget a remembered device
    #
    # The read-only commands require the `hardware:list` capability;
    # `hardware.forget` requires `hardware:manage`.
    class Hardware < Plugin::Base
      getter! api : Features::HardwareAPI

      struct MonitorRequest
        include JSON::Serializable
        getter types : Array(String)
        getter interval_ms : Int32 = 2000
      end

      def identifier : String
        "hardware"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(hardware.available hardware.list hardware.enumerate hardware.monitor.start hardware.monitor.stop), "hardware:list")
          .require("hardware.forget", "hardware:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(hardware:list hardware:manage),
          commands: %w(hardware.available hardware.list hardware.enumerate hardware.forget hardware.monitor.start hardware.monitor.stop),
          events: %w(hardware.changed),
          ipc: ipc,
        )
      end

      # The availability, list, and enumerate commands take a device-type
      # string and return `{"error" => ...}` when the type is unrecognized.
      # `hardware.forget` takes a device id and clears it from the API's
      # remembered set.
      def initialize_plugin(context : Plugin::Context) : Nil
        hapi = Features::HardwareAPI.new(context.capabilities)
        @api = hapi
        hapi.on_device_connected do |device|
          context.emit("hardware.changed", context.app.coerce_to_json({
            "type"   => "connected",
            "device" => device,
          }))
        end
        hapi.on_device_disconnected do |device_id|
          context.emit("hardware.changed", context.app.coerce_to_json({
            "type"      => "disconnected",
            "device_id" => device_id,
          }))
        end

        context.command "hardware.available", String do |type_str|
          ptype = Features::HardwareAPIType.parse?(type_str)
          next {"error" => "Unknown type: #{type_str}"} unless ptype
          {"available" => hapi.available?(ptype)}
        end

        context.command "hardware.list", String do |type_str|
          ptype = Features::HardwareAPIType.parse?(type_str)
          next {"error" => "Unknown type: #{type_str}"} unless ptype
          devices = hapi.list_devices(ptype)
          {"devices" => devices}
        end

        context.command "hardware.enumerate", String do |type_str|
          ptype = Features::HardwareAPIType.parse?(type_str)
          next {"error" => "Unknown type: #{type_str}"} unless ptype
          devices = hapi.enumerate(ptype)
          {"devices" => devices}
        end

        context.command "hardware.forget", String do |device_id|
          hapi.forget_device(device_id)
          {"success" => true}
        end

        context.command "hardware.monitor.start", MonitorRequest do |request|
          types = [] of Features::HardwareAPIType
          request.types.each do |value|
            if type = Features::HardwareAPIType.parse?(value)
              types << type
            else
              raise Core::Error.new("Unknown hardware type: #{value}", code: "BAD_REQUEST")
            end
          end
          hapi.start_monitoring(types, request.interval_ms.milliseconds)
          {"success" => true}
        end

        context.command "hardware.monitor.stop" do
          hapi.stop_monitoring
          {"success" => true}
        end
      end

      def cleanup_plugin : Nil
        @api.try(&.stop_monitoring)
      end
    end
  end
end
