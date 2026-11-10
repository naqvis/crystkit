require "../base"
require "../../features/draggable_region"

module CrystKit
  module Plugins
    # Plugin implementing frameless-window drag handles via an injected
    # JavaScript bridge.
    #
    # Lets the frontend declare window-drag regions on frameless enhanced
    # windows by stamping elements with a `data-cryst-drag` attribute.
    #
    # Registers IPC commands:
    #   window.enable_drag_region — inject the draggable-region bridge JS
    #   window.disable_drag_region — disable the draggable region
    #   window.move_by — move the focused enhanced window by a relative delta
    #
    # Required capability: `window:manage`
    #
    # ```
    # app.plugin(CrystKit::Plugins::DraggableRegion.new)
    # ```
    class DraggableRegion < Plugin::Base
      # :nodoc: Whether drag-region handling is currently enabled.
      @enabled = false

      def identifier : String
        "draggable_region"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(window.enable_drag_region window.disable_drag_region window.move_by), "window:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(window:manage),
          commands: %w(window.enable_drag_region window.disable_drag_region window.move_by),
          ipc: ipc,
        )
      end

      # `window.enable_drag_region` returns
      # `{"injected": true, "script_length": <int>}`.
      # `window.move_by(delta_x, delta_y)` returns `{"moved": <bool>}` —
      # `false` when the region is disabled or no eligible window exists.
      def initialize_plugin(context : Plugin::Context) : Nil
        context.command "window.enable_drag_region" do
          @enabled = true
          js = Features::DraggableRegion.js_bridge
          # init() re-runs on every navigation, so the bridge survives reloads.
          context.app.window_registry.all.each(&.init(js))
          {"injected" => true, "script_length" => js.size}
        end

        context.command "window.disable_drag_region" do
          @enabled = false
          # Tear down listeners on the next tick without requiring a reload.
          context.app.window_registry.all.each do |window|
            window.eval("window.__crystkit_drag_disabled = true;") rescue nil
          end
          {"injected" => false}
        end

        # Apply a relative move to the active (frameless) enhanced window.
        context.command "window.move_by", Int32, Int32 do |delta_x, delta_y|
          next {"moved" => false} unless @enabled
          window = active_window(context)
          next {"moved" => false} unless window
          window.move_by(delta_x, delta_y)
          {"moved" => true}
        end
      end

      # The window a drag should move: prefer a frameless enhanced window,
      # otherwise the first registered enhanced window. Returns `nil` when no
      # enhanced window is registered.
      # :nodoc:
      private def active_window(context : Plugin::Context) : ::CrystKit::Core::Window?
        windows = context.app.window_registry.all
        windows.find(&.frameless?) || windows.first?
      end
    end
  end
end
