require "json"
require "log"
require "../core/errors"
require "../security/capability"
require "../platform/host"

module CrystKit
  module Features
    # Helpers for working with platform target triples when locating sidecar
    # binaries. Wraps `Platform::Host.target_triple` and computes the
    # conventional sidecar filename of the form `<name>-<triple><ext>`.
    module TargetTriple
      # The host platform's target triple (e.g. `"x86_64-apple-darwin"`).
      def self.current : String
        Platform::Host.target_triple
      end

      # Compose the conventional sidecar filename for *name* on *triple*.
      #
      # Appends `.exe` on Windows triples; otherwise no extension. Used to
      # disambiguate per-platform sidecar binaries packed into a single
      # resource directory.
      def self.sidecar_filename(name : String, triple : String) : String
        ext = triple.includes?("windows") ? ".exe" : ""
        "#{name}-#{triple}#{ext}"
      end
    end

    # Outcome of a `SidecarManager#execute` invocation.
    struct SidecarResult
      # Captured stdout.
      getter stdout : String

      # Captured stderr.
      getter stderr : String

      # Exit code from the OS.
      getter exit_code : Int32

      # Build a `SidecarResult` from captured output and exit status.
      def initialize(@stdout : String, @stderr : String, @exit_code : Int32)
      end

      # Returns `true` when `exit_code == 0`.
      def success? : Bool
        @exit_code == 0
      end
    end

    # Configuration for a single sidecar execution.
    #
    # Default timeout is 30 seconds; exceeding it raises
    # `Core::TimeoutError`.
    struct SidecarOptions
      # Command-line arguments passed to the sidecar binary (excluding the
      # binary path).
      property args : Array(String)

      # Working directory the sidecar runs in. `nil` inherits the current
      # working directory.
      property cwd : Path?

      # Environment-variable overrides merged into the inherited process
      # environment. Empty by default.
      property env : Hash(String, String)

      # Maximum execution time. Exceeding it raises `Core::TimeoutError`.
      # `nil` waits forever.
      property timeout : Time::Span?

      # Build sidecar options with defaults.
      def initialize(
        @args : Array(String) = [] of String,
        @cwd = nil,
        @env : Hash(String, String) = Hash(String, String).new,
        @timeout = 30.seconds,
      )
      end
    end

    # Manager for bundled "sidecar" binaries shipped alongside the app.
    #
    # Sidecars are registered by a logical *name* (checked against the
    # `sidecar:execute` capability).
    class SidecarManager
      # :nodoc:
      Log = ::Log.for(self)

      @capabilities : Security::CapabilitySystem
      @sidecars : Hash(String, String)

      # Build a `SidecarManager` gated by *capabilities*.
      def initialize(@capabilities : Security::CapabilitySystem)
        @sidecars = Hash(String, String).new
      end

      # Map a logical *name* to *binary_path* on disk.
      #
      # `execute` refuses to run unregistered sidecars. Re-registering a name
      # overwrites the previous path.
      def register(name : String, binary_path : String)
        @sidecars[name] = binary_path
        Log.debug { "SidecarManager: registered '#{name}' at #{binary_path}" }
      end

      # Locate the sidecar binary on disk for *name* within *resource_dir*.
      #
      # Searches, in order:
      # 1. `<resource_dir>/sidecars/<name>-<triple><ext>`
      # 2. `<resource_dir>/sidecars/<name><ext>`
      # 3. `<resource_dir>/<name>-<triple><ext>`
      # 4. `<resource_dir>/<name><ext>`
      #
      # where `<triple>` is the current platform's target triple and `<ext>`
      # is the platform's executable extension (`.exe` on Windows, empty
      # otherwise). Returns the first existing path, or `nil` if no candidate
      # exists.
      #
      # ```
      # path = SidecarManager.resolve_sidecar_path(res_dir, "mycli")
      # ```
      def self.resolve_sidecar_path(resource_dir : String, name : String) : String?
        triple = current
        ext = Platform::Host.executable_extension

        sidecars_dir = File.join(resource_dir, "sidecars")
        suffixed = File.join(sidecars_dir, "#{name}-#{triple}#{ext}")
        return suffixed if File.exists?(suffixed)

        generic = File.join(sidecars_dir, "#{name}#{ext}")
        return generic if File.exists?(generic)

        suffixed = File.join(resource_dir, "#{name}-#{triple}#{ext}")
        return suffixed if File.exists?(suffixed)

        generic = File.join(resource_dir, "#{name}#{ext}")
        return generic if File.exists?(generic)

        nil
      end

      # Spawn the registered sidecar *sidecar_name* with *options*.
      #
      # The sidecar must accept input via arguments (stdin is closed).
      #
      # Raises `Core::SecurityError` if the `sidecar:execute` capability is
      # not granted for *sidecar_name*. Raises `Core::Error` if the
      # sidecar is not registered, its binary cannot be found, or execution
      # fails. Raises `Core::TimeoutError` if the timeout elapses.
      def execute(sidecar_name : String, options : SidecarOptions = SidecarOptions.new) : SidecarResult
        @capabilities.require!("sidecar:execute", sidecar_name)

        path = @sidecars[sidecar_name]? || raise Core::Error.new(
          "Sidecar '#{sidecar_name}' is not registered",
          code: "SIDECAR_NOT_FOUND"
        )

        stdout_io = IO::Memory.new
        stderr_io = IO::Memory.new

        env = build_env(options.env)
        cwd_str = options.cwd.try(&.to_s)

        process = Process.new(
          path,
          args: options.args,
          shell: false,
          input: Process::Redirect::Close,
          output: stdout_io,
          error: stderr_io,
          env: env,
          chdir: cwd_str
        )

        exit_code = wait_with_timeout(process, sidecar_name, options.timeout)

        Log.debug { "SidecarManager: '#{sidecar_name}' exited with code #{exit_code}" }

        SidecarResult.new(
          stdout: stdout_io.to_s,
          stderr: stderr_io.to_s,
          exit_code: exit_code
        )
      rescue ex : Core::SecurityError
        raise ex
      rescue ex : Core::TimeoutError
        raise ex
      rescue ex : File::NotFoundError | File::AccessDeniedError
        raise Core::Error.new(
          "Sidecar '#{sidecar_name}' binary not found: #{ex.message}",
          code: "SIDECAR_BINARY_NOT_FOUND"
        )
      rescue ex
        raise Core::Error.new(
          "Failed to execute sidecar '#{sidecar_name}': #{ex.message}",
          code: "SIDECAR_EXECUTION_FAILED"
        )
      end

      # Returns true when a sidecar with the given *name* has been registered.
      def registered?(name : String) : Bool
        @sidecars.has_key?(name)
      end

      # Returns the logical names of all currently registered sidecars.
      def registered_sidecars : Array(String)
        @sidecars.keys
      end

      # :nodoc:
      private def build_env(overrides : Hash(String, String)) : Hash(String, String)?
        return nil if overrides.empty?

        env = ENV.to_h
        overrides.each { |k, v| env[k] = v }
        env
      end

      # :nodoc:
      private def wait_with_timeout(process : Process, name : String, timeout : Time::Span?) : Int32
        if timeout.nil?
          return process.wait.exit_code
        end

        ch = Channel(Process::Status).new(1)

        Core::Fibers.spawn do
          status = process.wait
          ch.send(status) rescue nil
        end

        select
        when status = ch.receive
          status.exit_code
        when timeout(timeout)
          process.terminate(graceful: true) rescue nil
          Core::Fibers.spawn { ch.receive rescue nil }
          raise Core::TimeoutError.new("sidecar '#{name}'", timeout)
        end
      end
    end
  end
end
