require "json"
require "../../features/positioning"

module CrystKit
  module Plugins
    # Builtin plugin that exposes window positioning and display queries to the
    # frontend.
    #
    # Mutating snap/maximize operations require `positioning:manage`; read-only
    # display queries require `display:read`. All mutating commands operate on
    # the first window in the app's window registry, which is the convention
    # for single-window apps; multi-window apps should drive positioning
    # through the host directly.
    #
    # Registers IPC commands:
    #   positioning.snap, positioning.maximize,
    #   positioning.corner, positioning.edge,
    #   positioning.display_count, positioning.screen_info
    #
    # Required capabilities: `positioning:manage`, `display:read`
    class Positioning < Plugin::Base
      # :nodoc:
      def initialize(@provider : Features::PositioningProvider = Features::NativePositioningProvider.new)
      end

      # The `Features::WindowPositioner`, lazily initialized during
      # `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! positioner : Features::WindowPositioner

      # Returns the unique plugin identifier `"positioning"`.
      def identifier : String
        "positioning"
      end

      # Returns the metadata contract splitting positioning commands across
      # the `positioning:manage` and `display:read` capabilities.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(positioning.snap positioning.maximize positioning.corner positioning.edge), "positioning:manage")
          .require(%w(positioning.display_count positioning.screen_info), "display:read")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(positioning:manage display:read),
          commands: %w(positioning.snap positioning.maximize positioning.display_count positioning.screen_info positioning.corner positioning.edge),
          ipc: ipc,
        )
      end

      # Registers the six IPC commands.
      #
      # Mutating commands (`snap`, `maximize`, `corner`, `edge`) return
      # `{"success" => true}` on success or `{"success" => false, "error" =>
      # ...}` when no window is available or the direction/corner/edge string
      # could not be parsed. `corner` and `edge` take the window dimensions
      # from the frontend and return `{"x", "y"}` of the computed top-left
      # position without moving the window, letting the caller apply the move
      # itself. `display_count` returns `{"count"}` and `screen_info` returns
      # `{"bounds", "work_area", "display"}` for the given 0-based display
      # index, or `{"error"}` on an out-of-range index.
      def initialize_plugin(context) : Nil
        @positioner = Features::WindowPositioner.new(@provider)

        context.command "positioning.snap", String do |direction_s|
          snapped = parse_snap_direction(direction_s)
          next {"success" => false, "error" => "Unknown snap direction: #{direction_s}"} unless snapped

          wv = find_window(context)
          next {"success" => false, "error" => "No window"} unless wv

          positioner.snap(wv, snapped)
          {"success" => true}
        end

        context.command "positioning.maximize" do
          wv = find_window(context)
          next {"success" => false, "error" => "No window"} unless wv
          positioner.maximize(wv)
          {"success" => true}
        end

        context.command "positioning.display_count" do
          {"count" => positioner.display_count}
        end

        context.command "positioning.screen_info", Int32 do |display|
          begin
            info = positioner.screen_info(display)
            {
              "bounds"    => rect_to_h(info.bounds),
              "work_area" => rect_to_h(info.work_area),
              "display"   => info.display,
            }
          rescue ex
            {"error" => ex.message}
          end
        end

        context.command "positioning.corner", Int32, Int32, String do |window_w, window_h, corner_s|
          window_size = Features::Rectangle.new(0, 0, window_w, window_h)
          corner = Features::Corner.parse?(corner_s)
          next {"success" => false, "error" => "Unknown corner: #{corner_s}"} unless corner
          pt = positioner.position_at_corner(window_size, corner)
          {"x" => pt.x, "y" => pt.y}
        end

        context.command "positioning.edge", Int32, Int32, String do |window_w, window_h, edge_s|
          window_size = Features::Rectangle.new(0, 0, window_w, window_h)
          edge = Features::Edge.parse?(edge_s)
          next {"success" => false, "error" => "Unknown edge: #{edge_s}"} unless edge
          pt = positioner.position_at_edge(window_size, edge)
          {"x" => pt.x, "y" => pt.y}
        end
      end

      # :nodoc:
      private def find_window(context) : ::CrystKit::Core::EnhancedWindow?
        context.app.window_registry.all.first?.try(&.native)
      end

      # :nodoc:
      private def parse_snap_direction(s : String) : Features::SnapDirection?
        Features::SnapDirection.parse?(s)
      end

      # :nodoc:
      private def rect_to_h(r : Features::Rectangle) : Hash(String, Int32)
        {"x" => r.x, "y" => r.y, "width" => r.width, "height" => r.height}
      end
    end
  end
end
