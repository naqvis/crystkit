require "../base"
require "../../features/file_watcher"

module CrystKit
  module Plugins
    # Plugin watching filesystem paths for changes and bridging events to the
    # frontend.
    #
    # Each `fs.watch` call establishes a long-lived watch over a directory or
    # file and re-emits events as `fs.changed` IPC events.
    #
    # Registers IPC commands:
    #   fs:watch — Watch a path for file changes
    #   fs:unwatch — Stop watching a path
    #   fs:watchers — List watched paths
    # Emits events: fs.changed
    #
    # IPC policy: watching is gated by the `fs:read` capability. The path
    # passed to `fs.watch` is checked against path-scope rules, with the
    # recursive flag carried in the policy parameter slot.
    class FileWatcher < Plugin::Base
      getter! fw : Features::FileWatcher

      def identifier : String
        "file_watcher"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .path("fs.watch", "fs:read", "0", IPC::ResourcePermission::Read)
          .path("fs.unwatch", "fs:read", "", IPC::ResourcePermission::Read)
          .require("fs.watchers", "fs:read")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(fs:read),
          commands: %w(fs.watch fs.unwatch fs.watchers),
          events: %w(fs.changed),
          ipc: ipc,
        )
      end

      # `fs.watch` starts a watch on *path* (optionally recursive) and returns
      # `{"watching" => true, "path" => path}`; each file change emits an
      # `fs.changed` event with `type` and `path` fields. `fs.watchers` returns
      # the list of currently watched paths.
      def initialize_plugin(context : Plugin::Context) : Nil
        @fw = Features::FileWatcher.new

        context.command "fs.watch", String, Bool? do |path, recursive|
          Core::Fibers.spawn(name: "fw-emitter-#{path}") do
            begin
              channel = fw.watch(path, recursive || false)
              loop do
                break if channel.closed?
                event = channel.receive
                context.emit("fs.changed", context.app.coerce_to_json({"type" => event.type.to_s.downcase, "path" => event.path, "old_path" => event.old_path}))
              end
            rescue Channel::ClosedError
            end
          end
          context.app.coerce_to_json({"watching" => true, "path" => path})
        end

        context.command "fs.unwatch", String do |path|
          fw.unwatch(path)
          nil
        end

        context.command "fs.watchers" do
          {"paths" => fw.watcher_paths}
        end
      end

      def cleanup_plugin : Nil
        @fw.try(&.close)
      end
    end
  end
end
