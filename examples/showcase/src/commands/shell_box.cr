require "../../../../src/app/app"
require "../../../../src/features/shell"

# Sandbox for CrystKit::Features::ShellExecutor.
# Demonstrates capability enforcement, argument sanitization, timeouts.
module Showcase
  module Commands
    module ShellBox
      extend self

      def setup(app : CrystKit::App) : Nil
        executor = CrystKit::Features::ShellExecutor.new(app.security)

        app.async "shell.run", String, JSON::Any, Int32 do |command, args, timeout_ms, _cancel|
          arg_strs = args.as_a.map(&.as_s)
          {% if flag?(:windows) %}
            if command == "echo"
              command = "cmd.exe"
              arg_strs = ["/d", "/s", "/c", "echo"] + arg_strs
            end
          {% end %}
          opts = CrystKit::Features::ShellOptions.new(
            timeout: timeout_ms > 0 ? timeout_ms.milliseconds : nil,
          )
          result = executor.execute(command, arg_strs, opts)
          {
            "stdout"    => result.stdout,
            "stderr"    => result.stderr,
            "exit_code" => result.exit_code,
          }
        end
      end
    end
  end
end
