require "../base"
require "../../features/process"

module CrystKit
  module Plugins
    # Builtin plugin that exposes child-process spawning and lifecycle control
    # to the frontend.
    #
    # Spawning and kill/terminate are `Dangerous` resource policies keyed on
    # the command string or PID, while `process.list` is a `Sensitive`
    # capability-only read. The IPC resolver audits the exact command and
    # PID values before handlers run.
    #
    # Registers IPC commands:
    #   process:spawn — Spawn a child process with options
    #   process:kill — Kill a process by PID
    #   process:terminate — Terminate a process by PID
    #   process:list — List managed processes
    #
    # Required capabilities: `process:spawn`, `process:kill`, `process:list`
    class Process < Plugin::Base
      # IPC payload for `process.spawn` describing the command to run.
      #
      # *command* is the executable name or path; *args* is the argument
      # vector (empty by default). *cwd* optionally overrides the working
      # directory. *timeout*, when set, is interpreted as whole seconds after
      # which the spawned process is forcefully killed.
      struct SpawnRequest
        include JSON::Serializable
        # The executable name or path to run.
        getter command : String
        # Argument vector passed to the command; empty by default.
        getter args : Array(String) = [] of String
        # Optional working directory.
        getter cwd : String?
        # Optional timeout in whole seconds. When elapses, the child is
        # killed forcefully.
        getter timeout : Int32?
      end

      # IPC payload for `process.kill` and `process.terminate` identifying the
      # target process by PID.
      #
      # *pid* is the value returned by `process.spawn` and must match a
      # process previously spawned through `process.spawn`.
      struct PidRequest
        include JSON::Serializable
        # The PID of the tracked process to kill or terminate.
        getter pid : Int64
      end

      # The `Features::ProcessManager`, lazily initialized during
      # `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! pm : Features::ProcessManager

      # Returns the unique plugin identifier `"process"`.
      def identifier : String
        "process"
      end

      # Returns the metadata contract binding process commands to the
      # `process:spawn`, `process:kill`, and `process:list` capabilities.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .resource("process.spawn", "process:spawn", "command", IPC::RiskLevel::Dangerous)
          .resource("process.kill", "process:kill", "pid", IPC::RiskLevel::Dangerous)
          .resource("process.terminate", "process:kill", "pid", IPC::RiskLevel::Dangerous)
          .require("process.list", "process:list", IPC::RiskLevel::Sensitive)

        Plugin::Metadata.new(
          identifier,
          capabilities: ["process:spawn", "process:kill", "process:list"],
          commands: %w(process.spawn process.kill process.terminate process.list),
          ipc: ipc,
        )
      end

      # Registers the four IPC commands.
      #
      # `process.spawn` decodes a `SpawnRequest` and returns `{"pid"}`.
      # `process.kill` and `process.terminate` decode a `PidRequest` and
      # forcefully or gracefully terminate the tracked process. `process.list`
      # returns an array of `{"pid", "command"}` entries for every currently
      # tracked process.
      def initialize_plugin(context : Plugin::Context) : Nil
        @pm = pm = Features::ProcessManager.new(context.security)

        context.command "process.spawn", SpawnRequest do |request|
          options = Features::SpawnOptions.new
          options.working_dir = request.cwd if request.cwd
          if timeout = request.timeout
            options.timeout = timeout.seconds
          end

          child = pm.spawn(request.command, request.args, options)
          {"pid" => child.pid}
        end

        context.command "process.kill", PidRequest do |request|
          pm.kill(request.pid)
        end

        context.command "process.terminate", PidRequest do |request|
          pm.terminate(request.pid)
        end

        context.command "process.list" do
          pm.processes.map do |pid, child|
            {"pid" => pid, "command" => child.command}
          end
        end
      end
    end
  end
end
