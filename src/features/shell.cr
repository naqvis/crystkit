require "json"
require "log"
require "../core/errors"
require "../security/context"
require "../platform/host"

module CrystKit
  module Features
    # Holds the result of a completed shell command.
    struct ShellResult
      # Standard output captured from the command.
      getter stdout : String

      # Standard error output captured from the command.
      getter stderr : String

      # Exit code returned by the command process.
      getter exit_code : Int32

      def initialize(@stdout : String, @stderr : String, @exit_code : Int32)
      end

      # Returns true when the command exited with code 0.
      def success? : Bool
        @exit_code == 0
      end
    end

    # Configuration options for shell command execution.
    struct ShellOptions
      # Working directory for the command. Defaults to the current directory.
      property cwd : Path?

      # Additional environment variables to pass to the command.
      # These are merged with the current process environment.
      property env : Hash(String, String)

      # Maximum time to wait for the command to complete.
      # Defaults to 30 seconds. Set to nil for no timeout.
      property timeout : Time::Span?

      def initialize(
        @cwd = nil,
        @env : Hash(String, String) = Hash(String, String).new,
        @timeout = 30.seconds,
      )
      end
    end

    # Secure shell command executor.
    #
    # All execute operations require the "shell:execute" capability.
    class ShellExecutor
      @security : Security::Context

      # Build a `ShellExecutor` gated by *security*.
      #
      # The security context must grant the `shell:execute` resource capability
      # (and, for working-directory validation, execute permission on the
      # requested path) before any command can be run.
      def initialize(@security : Security::Context)
      end

      # Execute a shell command synchronously with the given arguments and options.
      #
      # The command is run directly (not through a shell) to avoid injection;
      # arguments are never interpolated into a command string.
      #
      # Returns a `ShellResult` containing stdout, stderr, and the exit code.
      #
      # Raises `Core::SecurityError` if the "shell:execute" capability is missing.
      # Raises `Core::FileSystemError` if the command cannot be found or started.
      # Raises `Core::TimeoutError` if the command exceeds the configured timeout.
      def execute(command : String, args : Array(String) = [] of String, options : ShellOptions = ShellOptions.new) : ShellResult
        @security.require_resource!("shell:execute", command)
        if cwd = options.cwd
          @security.require_path!("shell:execute", cwd, Security::Permission::Execute)
        end

        sanitized_args = sanitize_args(args)

        stdout_io = IO::Memory.new
        stderr_io = IO::Memory.new

        env = build_env(options.env)

        cwd_str = options.cwd.try(&.to_s)

        if Platform::Host.windows?
          if cwd_str
            Log.debug { "ShellExecutor: cwd=#{cwd_str}, exists=#{Dir.exists?(cwd_str)}, dir=#{File.directory?(cwd_str)}" }
            webview_dir = File.join(__DIR__, "..", "..")
            if env
              env["PATH"] = "#{webview_dir};#{env["PATH"]? || ENV["PATH"]}"
            else
              env = ENV.to_h
              env["PATH"] = "#{webview_dir};#{ENV["PATH"]}"
            end
          end
        end

        process = Process.new(
          command,
          args: sanitized_args,
          shell: false,
          input: Process::Redirect::Close,
          output: stdout_io,
          error: stderr_io,
          env: env,
          chdir: cwd_str
        )

        exit_code = wait_with_timeout(process, command, options.timeout)

        Log.debug { "ShellExecutor: '#{command}' exited with code #{exit_code}" }

        ShellResult.new(
          stdout: stdout_io.to_s,
          stderr: stderr_io.to_s,
          exit_code: exit_code
        )
      rescue ex : RuntimeError
        if ex.message == "Abnormal exit has no exit code"
          Log.warn { "ShellExecutor: child process '#{command}' terminated abnormally (cwd=#{options.cwd.try(&.to_s).inspect})" }
          raise Core::FileSystemError.new(
            "Failed to execute command '#{command}': child process crashed (cwd=#{options.cwd.try(&.to_s).inspect})",
            code: "CHILD_CRASHED"
          )
        end
        raise ex
      rescue ex : Core::SecurityError
        raise ex
      rescue ex : Core::TimeoutError
        raise ex
      rescue ex : File::NotFoundError | File::AccessDeniedError
        raise Core::FileSystemError.new(
          "Cannot execute command '#{command}': #{ex.message}",
          code: "COMMAND_NOT_FOUND"
        )
      rescue ex : Core::FileSystemError
        raise ex
      rescue ex
        raise Core::FileSystemError.new(
          "Failed to execute command '#{command}': #{ex.message}",
          code: "EXECUTE_FAILED"
        )
      end

      # Execute a shell command asynchronously.
      #
      # The block is called with the `ShellResult` when the command completes.
      def execute_async(command : String, args : Array(String) = [] of String, options : ShellOptions = ShellOptions.new, &block : ShellResult ->)
        Core::Fibers.spawn do
          result = execute(command, args, options)
          block.call(result)
        end
      end

      # Sanitize command arguments to prevent shell injection.
      #
      # Since we run commands directly (shell: false), arguments are passed
      # verbatim to the OS without shell interpretation. This method validates
      # that arguments do not contain null bytes, which could truncate strings
      # in some OS implementations.
      # :nodoc:
      private def sanitize_args(args : Array(String)) : Array(String)
        args.map do |arg|
          # Strip null bytes which could be used to truncate argument strings
          arg.gsub("\0", "")
        end
      end

      # Build the environment hash for the child process.
      # Merges the current process environment with the provided overrides.
      # Returns nil when no overrides are provided (inherits parent env).
      # :nodoc:
      private def build_env(overrides : Hash(String, String)) : Hash(String, String)?
        return nil if overrides.empty?

        env = ENV.to_h
        overrides.each { |k, v| env[k] = v }
        env
      end

      # Wait for a process to complete, enforcing an optional timeout.
      # Terminates the process and raises TimeoutError if the timeout is exceeded.
      # :nodoc:
      private def wait_with_timeout(process : Process, command : String, timeout : Time::Span?) : Int32
        if timeout.nil?
          return process.wait.exit_code
        end

        completed = Atomic(Bool).new(false)
        timed_out = Atomic(Bool).new(false)
        finished = Channel(Nil).new(1)
        Core::Fibers.spawn do
          select
          when finished.receive
          when timeout(timeout)
            if completed.compare_and_set(false, true)
              timed_out.set(true)
              process.terminate(graceful: true) rescue nil
            end
          end
        end

        status = process.wait
        finished.send(nil) if completed.compare_and_set(false, true)
        if timed_out.get
          raise Core::TimeoutError.new("shell command '#{command}'", timeout)
        end
        status.exit_code
      end
    end
  end
end
