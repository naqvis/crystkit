require "../base"
require "../../features/resource_manager"

module CrystKit
  module Plugins
    # Builtin plugin that exposes the application resource directory to the
    # frontend.
    #
    # Read commands (`resources.get_dir`, `resources.resolve`) require
    # `resources:read`; `resources.set_dir` requires `resources:write`
    # because it overrides the detected directory (typically only done from
    # tests or setup flows).
    #
    # Registers IPC commands:
    #   resources:get_dir — Get the resource directory path
    #   resources:resolve — Resolve a relative path to an absolute resource path
    #   resources:set_dir — Set the resource directory path
    #
    # Required capabilities: `resources:read`, `resources:write`
    class ResourceManager < Plugin::Base
      # Returns the unique plugin identifier `"resource_manager"`.
      def identifier : String
        "resource_manager"
      end

      # Returns the metadata contract splitting resource commands across the
      # `resources:read` and `resources:write` capabilities.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(resources.get_dir resources.resolve), "resources:read")
          .require("resources.set_dir", "resources:write")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(resources:read resources:write),
          commands: %w(resources.get_dir resources.resolve resources.set_dir),
          ipc: ipc,
        )
      end

      # Registers the three IPC commands against `Features::ResourceManager`.
      #
      # `resources.get_dir` returns `{"dir"}` with the cached or auto-detected
      # resource directory. `resources.resolve` joins the resource directory
      # with the relative *path* and returns `{"path"}` pointing at the
      # joined file when it exists, otherwise the input path unchanged.
      # `resources.set_dir` overrides the cached directory for the remainder
      # of the process.
      def initialize_plugin(context : Plugin::Context) : Nil
        context.command "resources.get_dir" do
          {"dir" => Features::ResourceManager.resource_dir}
        end

        context.command "resources.resolve", String do |relative_path|
          {"path" => Features::ResourceManager.resolve(relative_path)}
        end

        context.command "resources.set_dir", String do |path|
          Features::ResourceManager.resource_dir = path
        end
      end
    end
  end
end
