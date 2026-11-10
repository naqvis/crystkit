require "json"
require "../../features/display_manager"

module CrystKit
  module Plugins
    # Plugin exposing multi-monitor geometry to the frontend.
    #
    # Read-only: provides commands for observing display configuration, not
    # changing it.
    #
    # Registers IPC commands:
    #   display.list — full monitor list with bounds, work areas, scale
    #   display.count — number of monitors attached
    #   display.primary — the primary monitor's id/name/scale
    #
    # Required capability: `display:read`
    #
    # ```
    # app.plugin(CrystKit::Plugins::DisplayManager.new)
    # ```
    class DisplayManager < Plugin::Base
      getter! display_manager : Features::DisplayManager

      def identifier : String
        "display_manager"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(display.list display.count display.primary display.monitor_at), "display:read")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(display:read),
          commands: %w(display.list display.count display.primary display.monitor_at),
          ipc: ipc,
        )
      end

      # `display.list` returns `{"monitors": [...]}` where each entry has
      # `id`, `name`, `scale_factor`, `is_primary`, plus `bounds` and
      # `work_area` sub-objects (each with `x`, `y`, `width`, `height`).
      # `display.count` returns `{"count": <int>}`. `display.primary` returns
      # a minimal object with the primary monitor's `id`, `name`, and
      # `scale_factor`.
      def initialize_plugin(context) : Nil
        @display_manager = Features::DisplayManager.new

        context.command "display.list" do
          monitors = display_manager.monitors.map do |monitor|
            context.app.coerce_to_json({
              "id"           => monitor.id,
              "name"         => monitor.name,
              "scale_factor" => monitor.scale_factor,
              "is_primary"   => monitor.is_primary?,
              "bounds"       => context.app.coerce_to_json({
                "x"      => monitor.bounds.x,
                "y"      => monitor.bounds.y,
                "width"  => monitor.bounds.width,
                "height" => monitor.bounds.height,
              }),
              "work_area" => context.app.coerce_to_json({
                "x"      => monitor.work_area.x,
                "y"      => monitor.work_area.y,
                "width"  => monitor.work_area.width,
                "height" => monitor.work_area.height,
              }),
            })
          end
          {"monitors" => monitors}
        end

        context.command "display.count" do
          {"count" => display_manager.monitor_count}
        end

        context.command "display.primary" do
          m = display_manager.primary_monitor
          {"id" => m.id, "name" => m.name, "scale_factor" => m.scale_factor}
        end

        context.command "display.monitor_at", Int32 do |index|
          m = display_manager.monitor_at(index)
          if m
            {
              "id"           => m.id,
              "name"         => m.name,
              "scale_factor" => m.scale_factor,
              "is_primary"   => m.is_primary?,
              "bounds"       => {x: m.bounds.x, y: m.bounds.y, width: m.bounds.width, height: m.bounds.height},
              "work_area"    => {x: m.work_area.x, y: m.work_area.y, width: m.work_area.width, height: m.work_area.height},
            }
          end
        end
      end
    end
  end
end
