require "../../../../src/app/app"
require "../../../../src/features/process"

# ProcessManager sandbox: spawns a child, streams its stdout chunks to
# the frontend in real time via `on_stdout`, and emits a final
# `process:exit` event with the exit code when it terminates.
module Showcase
  module Commands
    module ProcessBox
      extend self

      def setup(app : CrystKit::App) : Nil
        manager = CrystKit::Features::ProcessManager.new(app.security)
        children = Hash(Int64, CrystKit::Features::ChildProcess).new

        app.async "process.spawn", String, JSON::Any do |command, args, _cancel|
          arg_strs = args.as_a.map(&.as_s)
          child = manager.spawn(command, arg_strs)
          children[child.pid] = child

          child.on_stdout { |chunk| app.emit("process:stdout", {"pid" => child.pid, "data" => chunk}) }
          child.on_stderr { |chunk| app.emit("process:stderr", {"pid" => child.pid, "data" => chunk}) }
          child.on_exit do |code|
            app.emit("process:exit", {"pid" => child.pid, "code" => code})
            children.delete(child.pid)
          end

          spawn { child.wait }

          {"pid" => child.pid}
        end

        app.command "process.kill", Int64 do |pid|
          if child = children[pid]?
            child.kill
            "killed"
          else
            "not_found"
          end
        end

        app.command "process.list" do
          children.keys
        end
      end
    end
  end
end
