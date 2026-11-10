require "json"
require "log"
require "../core/errors"
require "../security/context"
require "../platform/host"

module CrystKit
  module Features
    # Handle to a spawned child process, with stdout/stderr streaming,
    # stdin writing, exit callbacks, and timeout enforcement.
    class ChildProcess
      # Size of the buffer used when streaming stdout / stderr (bytes).
      STREAM_BUFFER_SIZE = 4096

      # PID of the spawned child process.
      getter pid : Int64

      # The command string (argv[0]).
      getter command : String

      # Full stdout output, populated after `wait` returns.
      getter stdout_output : String

      # Full stderr output, populated after `wait` returns.
      getter stderr_output : String

      @process : Process
      @stdout_io : IO::Memory
      @stderr_io : IO::Memory
      @stdin_io : IO::FileDescriptor?
      @stdout_fiber : Fiber?
      @stderr_fiber : Fiber?
      @exit_handlers : Array(Proc(Int32, Nil))
      @stdout_handlers : Array(Proc(String, Nil))
      @stderr_handlers : Array(Proc(String, Nil))
      @timeout : Time::Span?
      @timeout_fiber : Fiber?

      # Wrap an already-spawned `Process`.
      #
      # When *timeout* is set, the process is killed if it has not exited
      # within the span. Output produced before `wait` is called is still
      # captured. Application code creates instances via `ProcessManager#spawn`,
      # not directly.
      def initialize(@process : Process, @command, @timeout = nil)
        @pid = @process.pid.to_i64
        @stdout_io = IO::Memory.new
        @stderr_io = IO::Memory.new
        @stdout_output = ""
        @stderr_output = ""
        @exit_handlers = [] of Proc(Int32, Nil)
        @stdout_handlers = [] of Proc(String, Nil)
        @stderr_handlers = [] of Proc(String, Nil)

        # Start background fibers to drain stdout and stderr in chunks so we
        # can both buffer the full output AND stream each chunk to any
        # registered handlers as they arrive.
        if stdout = @process.output
          @stdout_fiber = spawn { drain(stdout, @stdout_io, @stdout_handlers, "stdout") }
        end

        if stderr = @process.error
          @stderr_fiber = spawn { drain(stderr, @stderr_io, @stderr_handlers, "stderr") }
        end

        @stdin_io = @process.input

        # Start timeout enforcement fiber if a timeout was specified.
        if t = @timeout
          @timeout_fiber = spawn do
            sleep t
            if running?
              Log.warn { "ProcessManager: process #{@pid} exceeded timeout of #{t.total_seconds}s, killing" }
              kill
            end
          end
        end
      end

      # Read from *src* in fixed-size chunks, appending each chunk to *buffer*
      # for later retrieval via `stdout_output` / `stderr_output` and fanning
      # out to every callback registered for this stream. Continues until EOF.
      # :nodoc:
      private def drain(src : IO, buffer : IO::Memory, handlers : Array(Proc(String, Nil)), stream_name : String)
        bytes = Bytes.new(STREAM_BUFFER_SIZE)
        loop do
          read = src.read(bytes)
          break if read == 0
          chunk = String.new(bytes[0, read])
          buffer.write(bytes[0, read])
          handlers.each do |handler|
            begin
              handler.call(chunk)
            rescue ex
              Log.warn { "ProcessManager: #{stream_name} handler raised for pid #{@pid}: #{ex.message}" }
            end
          end
        end
      rescue ex
        Log.warn { "ProcessManager: error reading #{stream_name} for pid #{@pid}: #{ex.message}" }
      end

      # Register a handler invoked with each chunk of stdout as it arrives.
      #
      # Chunks are decoded as UTF-8 and may split a logical line — buffer at
      # the application level if you need line-oriented data. Handlers are
      # called on the drain fiber, so they must not block.
      def on_stdout(&handler : String ->) : Nil
        @stdout_handlers << handler
      end

      # Register a handler invoked with each chunk of stderr as it arrives.
      #
      # Chunks are decoded as UTF-8 and may split a logical line — buffer at
      # the application level if you need line-oriented data. Handlers are
      # called on the drain fiber, so they must not block.
      def on_stderr(&handler : String ->) : Nil
        @stderr_handlers << handler
      end

      # Register a handler to be called when the process exits.
      #
      # The handler receives the exit code. Multiple handlers can be
      # registered; they are called in registration order.
      def on_exit(&handler : Int32 ->)
        @exit_handlers << handler
      end

      # Send data to the child process stdin.
      def write_stdin(data : String) : Nil
        if stdin = @stdin_io
          stdin.print(data)
          stdin.flush
        else
          raise Core::FileSystemError.new(
            "stdin is not available for process #{@pid}",
            code: "STDIN_UNAVAILABLE"
          )
        end
      rescue ex : Core::FileSystemError
        raise ex
      rescue ex
        raise Core::FileSystemError.new(
          "Failed to write to stdin for process #{@pid}: #{ex.message}",
          code: "STDIN_WRITE_ERROR"
        )
      end

      # Close stdin, signalling EOF to the child process.
      def close_stdin : Nil
        @stdin_io.try(&.close)
        @stdin_io = nil
      end

      # Wait for the process to finish, collect all output, and fire exit handlers.
      #
      # Returns the exit status code.
      def wait : Int32
        # Close stdin so the child can detect EOF
        close_stdin

        status = @process.wait

        # Collect buffered output
        @stdout_output = @stdout_io.to_s
        @stderr_output = @stderr_io.to_s

        unless status.normal_exit?
          Log.warn { "ChildProcess[#{@pid}]: abnormal exit, raw_status=0x#{status.system_exit_status.to_s(base: 16, upcase: true)}" }
        end

        exit_code = status.normal_exit? ? status.exit_code : -1

        # Emit exit event to all registered handlers
        @exit_handlers.each do |handler|
          begin
            handler.call(exit_code)
          rescue ex
            Log.warn { "ProcessManager: exit handler raised for pid #{@pid}: #{ex.message}" }
          end
        end

        exit_code
      end

      # Check whether the process is still running.
      def running? : Bool
        !@process.terminated?
      end

      # Terminate the process gracefully (SIGTERM on Unix, Ctrl+Break on Windows).
      def terminate : Nil
        @process.terminate(graceful: true)
      rescue ex
        Log.warn { "ProcessManager: terminate failed for pid #{@pid}: #{ex.message}" }
      end

      # Kill the process forcefully (SIGKILL on Unix, TerminateProcess on Windows).
      def kill : Nil
        @process.terminate(graceful: false)
      rescue ex
        Log.warn { "ProcessManager: kill failed for pid #{@pid}: #{ex.message}" }
      end
    end

    # Options for spawning a child process.
    struct SpawnOptions
      # Environment variables to set for the child process.
      # Merged with the current environment when *clear_env* is false.
      property env : Hash(String, String)

      # Working directory for the child process.
      # Defaults to the current working directory when nil.
      property working_dir : String?

      # Whether to clear the inherited environment before applying *env*.
      property? clear_env : Bool

      # Whether to run the command through the system shell.
      # When true, the shell (sh -c on Unix, cmd /c on Windows) handles PATH
      # resolution, glob expansion, and pipes — required when the executable
      # is not on the minimal PATH visible to GUI apps.
      property? shell : Bool

      # Optional timeout for the child process.
      # When set, the process is killed forcefully after this duration.
      property timeout : Time::Span?

      def initialize(
        @env : Hash(String, String) = Hash(String, String).new,
        @working_dir = nil,
        @clear_env = false,
        @shell = false,
        @timeout = nil,
      )
      end
    end

    # Process manager for spawning and managing child processes.
    #
    # All spawn operations require the "process:spawn" capability.
    # Terminate/kill operations require the "process:kill" capability.
    class ProcessManager
      @security : Security::Context

      def initialize(@security : Security::Context)
        @processes = Hash(Int64, ChildProcess).new
      end

      # :nodoc:
      getter processes : Hash(Int64, ChildProcess)

      # Spawn a child process with the given command and arguments.
      #
      # Captures stdout and stderr; stdin is writable via the returned
      # `ChildProcess` handle.
      #
      # Raises `Core::SecurityError` if the "process:spawn" capability is missing.
      # Raises `Core::FileSystemError` if the process cannot be started.
      def spawn(command : String, args : Array(String) = [] of String, options : SpawnOptions = SpawnOptions.new) : ChildProcess
        @security.require_resource!("process:spawn", command)
        if working_dir = options.working_dir
          @security.require_path!("process:spawn", Path[working_dir], Security::Permission::Execute)
        end

        env = build_env(options)

        if Platform::Host.windows?
          if (wd = options.working_dir) && !wd.empty?
            Log.debug { "ProcessManager: cwd=#{wd}, exists=#{Dir.exists?(wd)}, dir=#{File.directory?(wd)}" }
            webview_dir = File.join(__DIR__, "..", "..")
            path_ext = "#{webview_dir};#{ENV["PATH"]}"
            if env
              env["PATH"] = "#{webview_dir};#{env["PATH"]? || ENV["PATH"]}"
            else
              env = ENV.to_h
              env["PATH"] = path_ext
            end
          end
        end

        # When shell mode is requested, join command + args into a single
        # command string so the shell can perform tilde expansion, globbing,
        # pipes, and variable substitution. Passing args separately causes
        # `Process.new` to shell-escape each one, defeating the purpose of
        # shell mode — the user would see `ls ~/` fail with "No such file or
        # directory" because `~` is quoted and never expanded.
        if options.shell? && !args.empty?
          shell_command = String.build do |io|
            io << command
            args.each { |a| io << ' ' << a }
          end
          process = Process.new(
            shell_command,
            env: env,
            clear_env: options.clear_env?,
            shell: true,
            input: Process::Redirect::Pipe,
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Pipe,
            chdir: options.working_dir
          )
        else
          process = Process.new(
            command,
            args: args.empty? ? nil : args,
            env: env,
            clear_env: options.clear_env?,
            shell: options.shell?,
            input: Process::Redirect::Pipe,
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Pipe,
            chdir: options.working_dir
          )
        end

        child = ChildProcess.new(process, command, options.timeout)
        @processes[child.pid] = child

        Log.debug { "ProcessManager: spawned '#{command}' with pid #{child.pid}" }

        child
      rescue ex : Core::SecurityError
        raise ex
      rescue ex : File::NotFoundError | File::AccessDeniedError
        raise Core::FileSystemError.new(
          "Cannot spawn process '#{command}': #{ex.message}",
          code: "PROCESS_NOT_FOUND"
        )
      rescue ex : Core::FileSystemError
        raise ex
      rescue ex
        raise Core::FileSystemError.new(
          "Failed to spawn process '#{command}': #{ex.message}",
          code: "SPAWN_FAILED"
        )
      end

      # Gracefully terminate a tracked process by PID (sends SIGTERM on Unix).
      #
      # Raises `Core::SecurityError` if the "process:kill" capability is missing.
      # Raises `Core::FileSystemError` if no process with the given PID is tracked.
      def terminate(pid : Int64) : Nil
        @security.require_resource!("process:kill", pid.to_s)

        child = @processes[pid]? || raise Core::FileSystemError.new(
          "No tracked process with pid #{pid}",
          code: "PROCESS_NOT_FOUND"
        )

        child.terminate
        Log.debug { "ProcessManager: sent SIGTERM to pid #{pid}" }
      end

      # Forcefully kill a tracked process by PID (sends SIGKILL on Unix).
      #
      # Raises `Core::SecurityError` if the "process:kill" capability is missing.
      # Raises `Core::FileSystemError` if no process with the given PID is tracked.
      def kill(pid : Int64) : Nil
        @security.require_resource!("process:kill", pid.to_s)

        child = @processes[pid]? || raise Core::FileSystemError.new(
          "No tracked process with pid #{pid}",
          code: "PROCESS_NOT_FOUND"
        )

        child.kill
        Log.debug { "ProcessManager: sent SIGKILL to pid #{pid}" }
      end

      # Look up a previously spawned process by its PID.
      #
      # Returns nil if no process with that PID is tracked.
      def find(pid : Int64) : ChildProcess?
        @processes[pid]?
      end

      # Stop tracking a process. Call after the process has exited to free
      # the reference.
      def untrack(pid : Int64) : Nil
        @processes.delete(pid)
      end

      # Returns the PIDs of all currently tracked processes.
      def tracked_pids : Array(Int64)
        @processes.keys
      end

      # :nodoc:
      private def build_env(options : SpawnOptions) : Hash(String, String)?
        return nil if options.env.empty? && !options.clear_env?

        env = Hash(String, String).new

        unless options.clear_env?
          # Inherit current environment
          ENV.each { |k, v| env[k] = v }
        end

        # Apply overrides
        options.env.each { |k, v| env[k] = v }

        env
      end
    end
  end
end
