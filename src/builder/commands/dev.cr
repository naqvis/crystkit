require "signal"
require "log"
require "../config"
require "../shell"
require "../frontend"
require "../../features/file_watcher"

module CrystKit
  module Builder
    module Commands
      # Implements `crystkit dev` — the development workflow driver.
      #
      # Launches the frontend dev server (when a Node project is detected),
      # runs the Crystal app, and restarts it on file changes. Traps
      # `INT`/`TERM` for a clean shutdown. When `ci_mode?` is set, prompts
      # and color output are suppressed.
      class Dev
        # :nodoc:
        Log = ::Log.for(self)

        # The loaded project config, or `nil` when running without one.
        getter config : Config?
        @crystal_process : Process?
        @frontend_process : Process?
        @watcher : Features::FileWatcher?

        # Creates a dev runner. *config* may be `nil` to run with defaults.
        def initialize(@config = nil)
        end

        # Starts the dev workflow and blocks until interrupted.
        #
        # Exits non-zero on fatal errors.
        def run : Nil
          spawn_node_dev_server_if_node_project
          run_crystal_app
          start_file_watcher

          Signal::INT.trap { shutdown; exit(0) }
          Signal::TERM.trap { shutdown; exit(0) }

          sleep
        rescue ex
          Log.error { "Dev server failed: #{ex.message}" }
          exit 1
        end

        # When `true`, disables interactive prompts and color output for
        # CI environments. Set by the CLI's global `--ci` flag.
        property? ci_mode : Bool = false

        # :nodoc:
        private def spawn_node_dev_server_if_node_project
          dir = project_dir
          return unless Frontend.has_package_json?(dir)

          cmd = Frontend.detect_dev_command(dir)
          return unless cmd

          Log.info { "Starting frontend dev server: #{cmd}" }
          @frontend_process = Process.new(cmd, shell: true, chdir: dir,
            input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
          Core::Fibers.spawn do
            unless @frontend_process.try(&.wait.success?)
              Log.warn { "Frontend dev server exited unexpectedly: #{cmd}" }
            end
          end

          url = @config.try(&.build.dev_url) || "http://localhost:5173"
          Log.info { "Waiting for #{url} to become reachable..." }
          unless Shell.wait_for_url(url)
            Log.warn { "Timed out waiting for #{url}." }
          end
        end

        # :nodoc:
        private def run_crystal_app(dir : String? = nil) : Nil
          dir ||= project_dir
          entry = resolve_entry_point(dir)
          Log.info { "Starting Crystal app: crystal run #{entry}" }

          env = {} of String => String
          # When a Node dev server is running, pass its URL so the app
          # navigates there (HMR) instead of the asset protocol.
          if @frontend_process && (dev_url = @config.try(&.build.dev_url))
            env["CRYSTKIT_DEV_URL"] = dev_url
          end

          process = Process.new(
            "crystal", ["run", entry],
            chdir: dir,
            env: env,
            input: Process::Redirect::Inherit,
            output: Process::Redirect::Inherit,
            error: Process::Redirect::Inherit,
          )
          @crystal_process = process
          ready = Channel(Nil).new
          Core::Fibers.spawn do
            process.wait
          ensure
            @crystal_process = nil if @crystal_process == process
            ready.close
          end
          select
          when ready.receive?
            Log.warn { "Crystal app exited immediately — check for compile errors" }
          when timeout(2.seconds)
            # still running — good
          end
        end

        # :nodoc:
        private def resolve_entry_point(dir : String) : String
          %w[src/main.cr main.cr src/app.cr].each do |candidate|
            path = File.join(dir, candidate)
            return candidate if File.file?(path)
          end
          "src/main.cr"
        end

        # :nodoc:
        private def start_file_watcher
          dir = project_dir
          watcher = Features::FileWatcher.new
          ch1 = watcher.watch(File.join(dir, "src"))
          ch2 = watcher.watch(File.join(dir, "frontend"))

          Core::Fibers.spawn do
            loop do
              ch1.receive
              Log.info { "Change detected — restarting Crystal app" }
              restart_crystal_app(dir)
            rescue Channel::ClosedError
              break
            end
          end

          Core::Fibers.spawn do
            loop do
              ch2.receive
              Log.info { "Change detected — restarting Crystal app" }
              restart_crystal_app(dir)
            rescue Channel::ClosedError
              break
            end
          end

          @watcher = watcher
        end

        # :nodoc:
        private def restart_crystal_app(dir : String) : Nil
          stop_crystal_app
          run_crystal_app(dir)
        end

        # :nodoc:
        private def shutdown
          stop_crystal_app
          stop_frontend_server
          @watcher.try(&.close)
        end

        # :nodoc:
        private def stop_frontend_server : Nil
          process = @frontend_process
          @frontend_process = nil
          return unless process
          begin
            process.signal(Signal::TERM)
          rescue ex
            Log.debug { "Frontend server already stopped: #{ex.message}" }
          end
          begin
            process.wait
          rescue ex
            Log.debug { "Frontend server wait failed: #{ex.message}" }
          end
        end

        # :nodoc:
        private def stop_crystal_app : Nil
          process = @crystal_process
          @crystal_process = nil
          return unless process

          begin
            process.signal(Signal::TERM)
          rescue ex : RuntimeError | NotImplementedError
            Log.debug { "Crystal app process was already stopped: #{ex.message}" }
            return
          end

          Core::Fibers.spawn do
            sleep 3.seconds
            if process.exists?
              Log.warn { "Crystal app did not exit on TERM, sending KILL" }
              {% unless flag?(:win32) %}
                process.signal(Signal::KILL) rescue nil
              {% end %}
            end
          end

          begin
            process.wait
          rescue ex
            Log.debug { "Crystal app process was already reaped: #{ex.message}" }
          end
        end

        # :nodoc:
        private def project_dir : String
          @config.try(&.project_dir.to_s) || Dir.current
        end

        # Convenience factory that loads *config_path* (or auto-discovers it)
        # and returns a `Dev` instance, falling back to defaults on load
        # failure.
        def self.from_config(config_path : String? = nil) : Dev
          cfg = Config.load_or_default(config_path)
          Dev.new(config: cfg)
        rescue ex
          Log.warn { "Could not load config: #{ex.message}. Using defaults." }
          Dev.new
        end
      end
    end
  end
end
