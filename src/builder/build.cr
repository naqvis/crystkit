require "json"
require "log"
require "file_utils"
require "./config"
require "./dependencies"
require "./shell"
require "./frontend"

module CrystKit
  # The `Builder` namespace groups everything related to producing a runnable
  # CrystKit application: compilation, dependency installation, frontend
  # builds, the development server, and per-platform packaging.
  module Builder
    # Orchestrates a production build of a CrystKit application.
    #
    # `run` produces a compiled binary and returns the resulting
    # `BuildManifest`. The binary path is typically handed to
    # `Bundle::Bundler` for packaging.
    #
    # ```
    # cfg = CrystKit::Builder::Config.load_or_default("crystkit.json")
    # build = CrystKit::Builder::Build.new(cfg, output_dir: "./dist", release: true)
    # manifest = build.run
    # puts manifest.binary_path
    # ```
    class Build
      # :nodoc:
      Log = ::Log.for(self)

      # Serializable record describing a completed build.
      #
      # `Build#run` produces an instance and writes it to
      # `.crystkit-build.json` inside the output directory.
      struct BuildManifest
        include JSON::Serializable

        # Absolute or output-relative path to the compiled binary.
        property binary_path : String

        # Resolved Crystal entry point file used for the compilation.
        property entry_point : String

        # Whether the binary was compiled with `--release`.
        property? release : Bool

        # Output of `crystal --version` captured at build time, or `nil` if
        # the compiler could not be introspected.
        property crystal_version : String?

        # Unix millisecond timestamp marking when the build completed.
        property timestamp : Int64

        # Creates a manifest with all fields populated.
        def initialize(
          @binary_path : String,
          @entry_point : String,
          @release : Bool,
          @crystal_version : String?,
          @timestamp : Int64,
        )
        end
      end

      # The project configuration driving this build.
      getter config : Config

      # Directory where the binary and manifest are written.
      getter output_dir : String

      # Whether the Crystal compiler is invoked with `--release --no-debug`.
      getter? release : Bool

      # Whether the frontend build stage is skipped entirely.
      getter? skip_frontend : Bool

      # Configures a build.
      #
      # *output_dir* defaults to `./dist` and is created on demand. When
      # *skip_frontend* is truthy the frontend build step is skipped.
      # *binary_name* overrides the default derived from
      # `config.package.name`, and *extra_flags* are appended to the
      # `crystal build` invocation.
      def initialize(
        @config : Config,
        @output_dir = "./dist",
        @release = true,
        @skip_frontend = false,
        @binary_name : String? = nil,
        @extra_flags : Array(String) = [] of String,
      )
      end

      # Runs the full build pipeline and returns the resulting manifest.
      #
      # Raises on any stage failure.
      def run : BuildManifest
        Dir.mkdir_p(output_dir)
        ensure_dependencies
        build_frontend unless skip_frontend?
        binary = compile_binary
        manifest = record_build(binary)
        write_manifest(manifest)
        manifest
      end

      # Installs Crystal shard dependencies for the project, raising on failure.
      def ensure_dependencies : Nil
        CrystalDependencies.install(config.project_dir)
      end

      # Resolves the Crystal source file to compile.
      #
      # Resolution order:
      #
      # 1. `build.crystal_entry` from `crystkit.json`, if set and existing.
      # 2. A single `*.cr` file under `src/` or the project root that
      #    references `CrystKit::App.new`, `CrystKit::App.run`, or `app.run`.
      # 3. The conventional paths `src/main.cr`, `main.cr`, `src/app.cr`.
      #
      # Raises with an actionable message if no entry point can be found.
      def entry_point : String
        if e = config.build.crystal_entry
          path = config.resolve(e)
          raise "Crystal entry point not found: #{path}" unless File.exists?(path.to_s)
          return path.to_s
        end

        candidates = Dir.glob("{src/,}*.cr", config.project_dir.to_s)
          .select { |file_path|
            next false if file_path.includes?("_spec.cr")
            app_entry_file?(file_path)
          }

        if candidates.one?
          return candidates.first
        end

        %w[src/main.cr main.cr src/app.cr].each do |candidate|
          path = config.resolve(candidate)
          return path.to_s if File.exists?(path.to_s)
        end

        if !candidates.empty?
          Log.warn { "Multiple potential entry points found. Using the first match." }
          return candidates.first
        end

        raise "Could not find a Crystal entry point. Looked for src/main.cr, main.cr, src/app.cr. " \
              "Set build.crystal_entry in crystkit.json."
      end

      # :nodoc:
      private def app_entry_file?(file_path : String) : Bool
        File.each_line(file_path) do |line|
          return true if line.includes?("CrystKit::App.new") ||
                         line.includes?("CrystKit::App.run") ||
                         line.includes?("app.run")
        end
        false
      rescue File::NotFoundError | IO::Error
        false
      end

      # :nodoc:
      private def entry_point_relative_to_cwd : String
        absolute = Path[entry_point].expand
        begin
          cwd = Path[Dir.current].expand
          absolute.relative_to(cwd).to_s
        rescue ex
          Log.warn(exception: ex) { "Could not make entry point relative to cwd" }
          absolute.to_s
        end
      end

      # Returns the absolute path of the binary produced by the build.
      #
      # On Windows a `.exe` suffix is appended.
      def binary_output_path : String
        ext = {% if flag?(:win32) %} ".exe" {% else %} "" {% end %}
        name = @binary_name || config.package.name.gsub(/[^A-Za-z0-9_.-]/, "_")
        (Path[output_dir] / "#{name}#{ext}").to_s
      end

      # :nodoc:
      private def build_frontend : Nil
        cmd = auto_detect_build_command
        unless cmd
          Log.debug { "No frontend build command detected; skipping." }
          return
        end

        Log.info { "Building frontend: #{cmd}" }
        unless Shell.run_with_shell(cmd, chdir: config.project_dir.to_s)
          raise "Frontend build failed: `#{cmd}`"
        end
      end

      # :nodoc:
      private def auto_detect_build_command : String?
        override = config.build.before_build_command
        return override if override

        project_dir = config.project_dir.to_s

        if Frontend.has_package_json?(project_dir)
          cmd = Frontend.detect_build_command(project_dir)
          if cmd
            Log.info { "Auto-detected frontend build: #{cmd}" }
            return cmd
          else
            Log.debug { "package.json found but no 'build' script defined." }
          end
        end

        nil
      end

      # :nodoc:
      private def compile_binary : String
        Shell.require_executable("crystal")

        entry = entry_point_relative_to_cwd
        binary_out = binary_output_path

        args = ["build", entry, "-o", binary_out]
        args << "--release" if release?
        args << "--no-debug" if release?
        args.concat(config.build.crystal_flags)
        args.concat(@extra_flags)

        Log.info { "Compiling #{entry} → #{binary_out}#{release? ? " (release)" : ""}" }
        unless Shell.exec("crystal", args)
          raise "Crystal compilation failed."
        end

        File.chmod(binary_out, 0o755) if File.exists?(binary_out)
        Log.info { "Built binary: #{binary_out}" }
        binary_out
      end

      # :nodoc:
      private def record_build(binary : String) : BuildManifest
        crystal_ver = begin
          result = Shell.capture("crystal", "--version")
          result.output.lines.first?.try(&.strip)
        rescue ex : File::NotFoundError | IO::Error
          Log.warn(exception: ex) { "Failed to capture crystal version for manifest" }
          nil
        end

        BuildManifest.new(
          binary_path: binary,
          entry_point: entry_point,
          release: release?,
          crystal_version: crystal_ver,
          timestamp: Time.utc.to_unix_ms,
        )
      end

      # :nodoc:
      private def write_manifest(manifest : BuildManifest) : Nil
        manifest_path = Path[output_dir] / ".crystkit-build.json"
        File.write(manifest_path.to_s, manifest.to_pretty_json)
        Log.info { "Build manifest: #{manifest_path}" }
      end
    end
  end
end
