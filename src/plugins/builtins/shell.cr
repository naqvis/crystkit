require "../base"
require "../../features/shell"

module CrystKit
  module Plugins
    # Builtin plugin that lets the frontend execute arbitrary shell commands
    # through the security-gated `Features::ShellExecutor`.
    #
    # This is one of the most dangerous surfaces CrystKit exposes: a granted
    # `shell:execute` capability allows running arbitrary processes on the
    # host. Both commands are declared `RiskLevel::Dangerous` and the
    # per-command `command` field is bound to the `shell:execute` capability
    # as a resource. Only grant this capability to trusted frontends.
    #
    # Registers IPC commands:
    #   shell:execute — Execute a shell command with options
    #   shell:execute_sync — Execute a shell command synchronously
    #
    # Required capability: `shell:execute` (per-command resource scoped,
    # dangerous risk)
    class Shell < Plugin::Base
      # IPC payload for `shell.execute`.
      #
      # *command* is the program to run and is the resource value authorized
      # against the `shell:execute` capability. *args* is the list of
      # positional arguments passed to the program. *cwd* is an optional
      # working directory. *timeout* is an optional wall-clock limit in
      # seconds; the underlying executor enforces it.
      struct ExecuteRequest
        include JSON::Serializable
        getter command : String
        getter args : Array(String) = [] of String
        getter cwd : String?
        getter timeout : Int32?
      end

      # IPC payload for `shell.execute_sync`.
      #
      # The synchronous variant only carries the *command* to run; it inherits
      # the executor's default working directory and no timeout. The command is
      # the resource value authorized against `shell:execute`.
      struct ExecuteSyncRequest
        include JSON::Serializable
        getter command : String
      end

      # The shell executor, constructed with the app's security context so every
      # invocation is capability-checked. Raises `NilAssertionError` if
      # accessed before the plugin has been initialized.
      getter! executor : Features::ShellExecutor

      # Returns the unique plugin identifier `"shell"`.
      def identifier : String
        "shell"
      end

      # Returns the metadata contract marking both commands as dangerous and
      # binding each command's `command` argument to the `shell:execute`
      # resource. The `command` field is authorized against `shell:execute`
      # per invocation.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .resource("shell.execute", "shell:execute", "command", IPC::RiskLevel::Dangerous)
          .resource("shell.execute_sync", "shell:execute", "command", IPC::RiskLevel::Dangerous)

        Plugin::Metadata.new(
          identifier,
          capabilities: ["shell:execute"],
          commands: %w(shell.execute shell.execute_sync),
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # Both commands return `{stdout, stderr, exit_code, success}`. The
      # async `shell.execute` honors `cwd` and `timeout` from the request;
      # `shell.execute_sync` runs with executor defaults.
      def initialize_plugin(context : Plugin::Context) : Nil
        @executor = ex = Features::ShellExecutor.new(context.security)

        context.command "shell.execute", ExecuteRequest do |request|
          options = Features::ShellOptions.new
          if cwd = request.cwd
            options.cwd = Path[cwd]
          end
          if timeout = request.timeout
            options.timeout = timeout.seconds
          end

          request.args.each do |arg|
            raise Core::Error.new("Null byte in shell argument", code: "BAD_ARGUMENT") if arg.includes?('\0')
          end

          result = ex.execute(request.command, request.args, options)
          {
            "stdout"    => result.stdout,
            "stderr"    => result.stderr,
            "exit_code" => result.exit_code,
            "success"   => result.success?,
          }
        end

        context.command "shell.execute_sync", ExecuteSyncRequest do |request|
          result = ex.execute(request.command)
          {
            "stdout"    => result.stdout,
            "stderr"    => result.stderr,
            "exit_code" => result.exit_code,
            "success"   => result.success?,
          }
        end
      end
    end
  end
end
