require "log"
require "process"
require "http/client"
require "uri"

module CrystKit
  module Builder
    # Thin wrappers around `Process` for running external commands.
    #
    # Provides both inheriting variants (which stream stdio to the parent
    # terminal, suitable for user-facing commands) and capturing variants
    # (which collect output into a `CommandResult`, suitable for
    # programmatic inspection), plus helpers for checking executable
    # availability and waiting for an HTTP server to become reachable.
    module Shell
      # :nodoc:
      Log = ::Log.for(self)

      # Outcome of a captured process execution.
      #
      # Returned by `capture`; carries the success flag, numeric exit code,
      # stdout, and stderr.
      record CommandResult, success : Bool, exit_code : Int32, output : String, stderr : String = "" do
        def success? : Bool
          success
        end
      end

      # Runs *command* with *args*, inheriting stdio to the terminal.
      #
      # Returns `true` on a zero exit status.
      def self.run(command : String, *args : String, chdir : String? = nil, env : Hash(String, String)? = nil, timeout : Time::Span? = nil) : Bool
        Log.info { "→ #{command} #{args.join(" ")}#{chdir ? " (in #{chdir})" : ""}" }
        if timeout
          process = Process.new(command, args.to_a, chdir: chdir, env: env,
            input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
          status_ch = Channel(Process::Status).new
          Core::Fibers.spawn { status_ch.send(process.wait) }
          select
          when status = status_ch.receive
            status.success?
          when timeout(timeout)
            process.terminate rescue nil
            process.wait rescue nil
            false
          end
        else
          Process.run(command, args: args.to_a,
            input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit,
            chdir: chdir, env: env).success?
        end
      end

      # Runs *command* with *args*, capturing stdout and stderr into a `CommandResult`.
      def self.capture(command : String, *args : String, chdir : String? = nil, env : Hash(String, String)? = nil, timeout : Time::Span? = nil) : CommandResult
        io_out = IO::Memory.new
        io_err = IO::Memory.new
        if timeout
          process = Process.new(command, args.to_a, chdir: chdir, env: env,
            input: Process::Redirect::Close, output: io_out, error: io_err)
          status_ch = Channel(Process::Status).new
          Core::Fibers.spawn { status_ch.send(process.wait) }
          select
          when status = status_ch.receive
            CommandResult.new(status.success?, status.exit_code, io_out.to_s, io_err.to_s)
          when timeout.sleep
            process.terminate rescue nil
            process.wait rescue nil
            CommandResult.new(false, -1, io_out.to_s, io_err.to_s)
          end
        else
          status = Process.run(command, args: args.to_a,
            input: Process::Redirect::Close, output: io_out, error: io_err,
            chdir: chdir, env: env)
          CommandResult.new(status.success?, status.exit_code, io_out.to_s, io_err.to_s)
        end
      end

      # Runs *executable* with the array *args*, inheriting stdio.
      #
      # Like `run` but accepts an `Array(String)` for the arguments.
      def self.exec(executable : String, args : Array(String), chdir : String? = nil, env : Hash(String, String)? = nil, timeout : Time::Span? = nil) : Bool
        Log.info { "→ #{executable} #{args.join(" ")}#{chdir ? " (in #{chdir})" : ""}" }
        if timeout
          process = Process.new(executable, args, chdir: chdir, env: env,
            input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
          status_ch = Channel(Process::Status).new
          Core::Fibers.spawn { status_ch.send(process.wait) }
          select
          when status = status_ch.receive
            status.success?
          when timeout.sleep
            process.terminate rescue nil
            process.wait rescue nil
            false
          end
        else
          Process.run(executable, args: args,
            input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit,
            chdir: chdir, env: env).success?
        end
      end

      # Returns `true` when *executable* is found on `PATH`.
      def self.which?(executable : String) : Bool
        Process.find_executable(executable) != nil
      end

      # Polls *url* with HTTP GET until it responds, returning `true`.
      #
      # Returns `false` if *url* does not become reachable within *timeout*
      # (default 60 seconds), polling every *interval* (default 0.5
      # seconds).
      def self.wait_for_url(url : String, timeout : Time::Span = 60.seconds, interval : Time::Span = 0.5.seconds) : Bool
        deadline = Time.instant + timeout
        Log.info { "Waiting for #{url} ..." }

        while Time.instant < deadline
          begin
            HTTP::Client.get(url) { |_| return true }
          rescue
          end
          sleep interval
        end
        false
      end

      # Runs *command* through the system shell, inheriting stdio.
      #
      # Use this when the command contains pipes, redirects, or other
      # shell syntax. Returns `true` on a zero exit status.
      #
      # On Unix this uses bash when available so user-supplied commands may
      # use bash syntax, falling back to `/bin/sh`. On Windows it uses the
      # system command shell. Only pass trusted commands.
      def self.run_with_shell(command : String, chdir : String? = nil, env : Hash(String, String)? = nil) : Bool
        Log.info { "→ #{command}#{chdir ? " (in #{chdir})" : ""}" }
        status = {% if flag?(:win32) %}
                   Process.run(
                     command,
                     shell: true,
                     input: Process::Redirect::Inherit,
                     output: Process::Redirect::Inherit,
                     error: Process::Redirect::Inherit,
                     chdir: chdir,
                     env: env,
                   )
                 {% else %}
                   shell = which?("bash") ? "bash" : "/bin/sh"
                   Process.run(
                     shell,
                     args: ["-c", command],
                     input: Process::Redirect::Inherit,
                     output: Process::Redirect::Inherit,
                     error: Process::Redirect::Inherit,
                     chdir: chdir,
                     env: env,
                   )
                 {% end %}
        status.success?
      end

      # Raises unless *name* is found on `PATH`.
      def self.require_executable(name : String) : Nil
        return if which?(name)
        raise "Required executable '#{name}' not found on PATH."
      end
    end
  end
end
