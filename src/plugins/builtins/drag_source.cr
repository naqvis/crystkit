require "json"
require "../../features/drag_source"

module CrystKit
  module Plugins
    # Plugin letting the frontend initiate OS-level drag operations out of the
    # application window.
    #
    # Registers IPC commands:
    #   drag_source.start_file — Begin dragging a local file path
    #   drag_source.start_text — Begin dragging an arbitrary text payload
    #   drag_source.start_url  — Begin dragging a URL
    #   drag_source.start_image — Begin dragging an image file
    #
    # Required capability: `drag:source`
    #
    # Each command returns `{"success": <bool>}` indicating whether the drag
    # was successfully started.
    #
    # ```
    # app.plugin(CrystKit::Plugins::DragSource.new)
    # ```
    class DragSource < Plugin::Base
      getter! source : Features::DragSource

      def identifier : String
        "drag_source"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(drag_source.start_file drag_source.start_text drag_source.start_url drag_source.start_image), "drag:source")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(drag:source),
          commands: %w(drag_source.start_file drag_source.start_text drag_source.start_url drag_source.start_image),
          ipc: ipc,
        )
      end

      def initialize_plugin(context) : Nil
        @source = Features::DragSource.new(context.capabilities)

        context.command_context "drag_source.start_file" do |invocation, params|
          {"success" => with_window(invocation) { source.start_file_drag(params.as_s) }}
        end

        context.command_context "drag_source.start_text" do |invocation, params|
          {"success" => with_window(invocation) { source.start_text_drag(params.as_s) }}
        end

        context.command_context "drag_source.start_url" do |invocation, params|
          {"success" => with_window(invocation) { source.start_url_drag(params.as_s) }}
        end

        context.command_context "drag_source.start_image" do |invocation, params|
          {"success" => with_window(invocation) { source.start_image_drag(params.as_s) }}
        end
      end

      def cleanup_plugin : Nil
        @source.try(&.cleanup)
      end

      private def with_window(invocation : IPC::Context, &block : -> Bool) : Bool
        return false unless window = invocation.window
        source.attach(window)
        block.call
      end
    end
  end
end
