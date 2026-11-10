require "../base"
require "../../features/fs"

module CrystKit
  module Plugins
    # Filesystem plugin exposing read, write, delete, and transfer operations
    # to the frontend via typed IPC.
    #
    # Every command is authorized through path-scoped IPC policies.
    #
    # Read commands (`fs.read_text`, `fs.read_binary`, `fs.exists`, `fs.list_dir`,
    # `fs.metadata`) require the `fs:read` capability; writes (`fs.write_text`,
    # `fs.write_binary`, `fs.create_dir`) require `fs:write`; deletion
    # (`fs.remove_file`, `fs.remove_dir`) requires `fs:delete`.
    class FS < Plugin::Base
      # IPC payload for commands that take a single path argument
      # (`fs.read_text`, `fs.read_binary`, `fs.exists`, `fs.list_dir`,
      # `fs.metadata`, `fs.write_text`, `fs.remove_file`, `fs.create_dir`).
      struct PathRequest
        include JSON::Serializable
        getter path : String
      end

      # IPC payload for `fs.write_text` carrying the file content to write.
      struct WriteTextRequest
        include JSON::Serializable
        getter path : String
        getter content : String
      end

      # IPC payload for `fs.write_binary` carrying base64-encoded data.
      struct WriteBinaryRequest
        include JSON::Serializable
        getter path : String
        getter data : String
      end

      # IPC payload for `fs.create_dir`.
      #
      # *recursive* defaults to `false`; when true the directory is created
      # with all intermediate parents (ala `mkdir -p`).
      struct CreateDirRequest
        include JSON::Serializable
        getter path : String
        getter? recursive : Bool = false
      end

      # IPC payload for the `fs.copy` and `fs.move` transfer commands.
      struct TransferRequest
        include JSON::Serializable
        getter source : String
        getter dest : String
      end

      getter! fs : Features::FileSystem

      def identifier : String
        "fs"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .path("fs.read_text", "fs:read", "path", IPC::ResourcePermission::Read)
          .path("fs.exists", "fs:read", "path", IPC::ResourcePermission::Read)
          .path("fs.list_dir", "fs:read", "path", IPC::ResourcePermission::Read)
          .path("fs.metadata", "fs:read", "path", IPC::ResourcePermission::Read)
          .path("fs.write_text", "fs:write", "path", IPC::ResourcePermission::Write, IPC::RiskLevel::Sensitive)
          .path("fs.create_dir", "fs:write", "path", IPC::ResourcePermission::Write, IPC::RiskLevel::Sensitive)
          .path("fs.remove_file", "fs:delete", "path", IPC::ResourcePermission::Write, IPC::RiskLevel::Dangerous)
          .path("fs.remove_dir", "fs:delete", "path", IPC::ResourcePermission::Write, IPC::RiskLevel::Dangerous)
          .path("fs.trash_delete", "fs:delete", "path", IPC::ResourcePermission::Write, IPC::RiskLevel::Dangerous)
          .path("fs.read_binary", "fs:read", "path", IPC::ResourcePermission::Read)
          .path("fs.write_binary", "fs:write", "path", IPC::ResourcePermission::Write, IPC::RiskLevel::Sensitive)
          .resource("fs.copy", IPC::CommandPolicy.new(resources: [
            IPC::ResourceRule.new("fs:read", IPC::ResourceKind::Path, "source", IPC::ResourcePermission::Read),
            IPC::ResourceRule.new("fs:write", IPC::ResourceKind::Path, "dest", IPC::ResourcePermission::Write),
          ], risk: IPC::RiskLevel::Sensitive))
          .resource("fs.move", IPC::CommandPolicy.new(resources: [
            IPC::ResourceRule.new("fs:write", IPC::ResourceKind::Path, "source", IPC::ResourcePermission::Write),
            IPC::ResourceRule.new("fs:write", IPC::ResourceKind::Path, "dest", IPC::ResourcePermission::Write),
          ], risk: IPC::RiskLevel::Dangerous))

        Plugin::Metadata.new(
          identifier,
          capabilities: ["fs:read", "fs:write", "fs:delete"],
          commands: %w(
            fs.read_text fs.write_text fs.exists fs.remove_file fs.remove_dir fs.create_dir
            fs.copy fs.move fs.list_dir fs.metadata fs.read_binary fs.write_binary fs.trash_delete
          ),
          ipc: ipc,
        )
      end

      # Mutating commands return `"ok"` on success. `fs.list_dir` returns an
      # array of `{name, path, type, size, modified_at}` entries, and
      # `fs.metadata` returns `{size, created_at, modified_at, permissions}`
      # with `permissions` formatted as an octal string.
      def initialize_plugin(context : Plugin::Context) : Nil
        @fs = fs = Features::FileSystem.new(context.security)

        context.command("fs.read_text", PathRequest) { |request| fs.read_text(Path[request.path]) }
        context.command("fs.write_text", WriteTextRequest) { |request| fs.write_text(Path[request.path], request.content); "ok" }
        context.command("fs.exists", PathRequest) { |request| fs.exists?(Path[request.path]) }
        context.command("fs.remove_file", PathRequest) { |request| fs.remove_file(Path[request.path]); "ok" }
        context.command("fs.remove_dir", CreateDirRequest) { |request| fs.remove_dir(Path[request.path], recursive: request.recursive?); "ok" }
        context.command("fs.trash_delete", PathRequest) { |request| fs.trash_delete(Path[request.path]); "ok" }
        context.command("fs.create_dir", CreateDirRequest) { |request| fs.create_dir(Path[request.path], recursive: request.recursive?); "ok" }
        context.command("fs.read_binary", PathRequest) { |request| Base64.encode(fs.read_binary(Path[request.path])) }
        context.command("fs.write_binary", WriteBinaryRequest) { |request| fs.write_binary(Path[request.path], Base64.decode(request.data)); "ok" }
        context.command("fs.copy", TransferRequest) { |request| fs.copy(Path[request.source], Path[request.dest]); "ok" }
        context.command("fs.move", TransferRequest) { |request| fs.move(Path[request.source], Path[request.dest]); "ok" }

        context.command("fs.list_dir", PathRequest) do |request|
          fs.list_dir(Path[request.path]).map do |e|
            {
              "name"        => e.name,
              "path"        => e.path.to_s,
              "type"        => e.type.to_s.downcase,
              "size"        => e.size,
              "modified_at" => e.modified_at.to_rfc3339,
            }
          end
        end

        context.command("fs.metadata", PathRequest) do |request|
          m = fs.metadata(Path[request.path])
          {
            "size"        => m.size,
            "created_at"  => m.created_at.to_rfc3339,
            "modified_at" => m.modified_at.to_rfc3339,
            "permissions" => m.permissions.to_s(8),
          }
        end
      end
    end
  end
end
