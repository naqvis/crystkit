require "../base"
require "../../features/dpi_monitor"

module CrystKit
  module Plugins
    # Plugin exposing the current display's DPI/scale info to the frontend.
    #
    # Reports the scale factor and dimensions of the monitor currently hosting
    # the application.
    #
    # Registers IPC commands:
    #   display.scale_factor — Get the current display scale factor
    #   display.info — Get current display info (name, scale, size)
    #
    # Required capability: `display:read`
    #
    # ```
    # app.plugin(CrystKit::Plugins::DPI.new)
    # ```
    class DPI < Plugin::Base
      getter! monitor : Features::DPIMonitor

      def identifier : String
        "dpi"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(display.scale_factor display.info), "display:read")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(display:read),
          commands: %w(display.scale_factor display.info),
          ipc: ipc,
        )
      end

      # `display.scale_factor` returns `{"scale": <float>}` — the multiplier
      # to apply to logical pixels to match physical pixels on the current
      # display. `display.info` returns
      # `{"name": ..., "scale": ..., "width": ..., "height": ...}`.
      def initialize_plugin(context : Plugin::Context) : Nil
        @monitor = dm = Features::DPIMonitor.new

        context.command "display.scale_factor" do
          {"scale" => dm.current_scale_factor}
        end

        context.command "display.info" do
          info = dm.current_display
          {"name" => info.name, "scale" => info.scale_factor, "width" => info.width, "height" => info.height}
        end
      end
    end
  end
end
