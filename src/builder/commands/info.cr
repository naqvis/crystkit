require "log"
require "../../features/system_info"
require "../shell"

module CrystKit
  module Builder
    module Commands
      # Implements `crystkit info` — prints a human-readable summary of the
      # CrystKit CLI, Crystal toolchain, OS, architecture, webview
      # backend, and (when present) the current project's config.
      class Info
        # :nodoc:
        Log = ::Log.for(self)

        # Prints the system information report to stdout.
        def run
          puts "─" * 50
          puts " CrystKit CLI — System Information"
          puts "─" * 50
          puts ""

          cli_version
          crystal_version
          os_info
          arch_info
          webview_info
          project_info

          puts ""
          puts "─" * 50
        end

        # :nodoc:
        private def crystal_version
          print " Crystal  "
          result = Shell.capture("crystal", "--version")
          if result.success
            puts result.output.lines.first?.try(&.strip) || "unknown"
          else
            puts "NOT FOUND"
            puts "          Install: https://crystal-lang.org/install"
          end
        rescue File::NotFoundError
          puts "NOT FOUND"
          puts "          Install: https://crystal-lang.org/install"
        rescue ex : IO::Error
          Log.warn(exception: ex) { "Unexpected error detecting Crystal version" }
          puts "NOT FOUND"
          puts "          Install: https://crystal-lang.org/install"
        end

        # :nodoc:
        private def os_info
          info = Features::SystemInfo.new
          os = info.os_info
          puts " OS       #{os.name} #{os.version}"
        end

        # :nodoc:
        private def arch_info
          info = Features::SystemInfo.new
          puts " Arch     #{info.architecture}"
          puts " Hostname #{info.hostname}"
          cpu = info.cpu_info
          puts " CPU      #{cpu}"
        end

        # :nodoc:
        private def webview_info
          print " Webview  "
          {% if flag?(:darwin) %}
            puts "WebKit (built-in macOS)"
          {% elsif flag?(:linux) %}
            if Dir.glob("/usr/lib/**/libwebkit2gtk*").any? { |path| File.file?(path) }
              puts "WebKitGTK (system)"
            else
              puts "NOT FOUND"
              puts "          Install: sudo apt install libwebkit2gtk-4.1-dev"
            end
          {% elsif flag?(:win32) %}
            puts "WebView2 (built-in Windows 10+)"
          {% else %}
            puts "unknown"
          {% end %}
        end

        # :nodoc:
        private def cli_version
          puts " CLI      CrystKit Builder v#{VERSION}"
          result = Shell.capture("shards", "--version")
          if result.success?
            puts " Shards   #{result.output.strip}"
          else
            puts " Shards   NOT FOUND"
          end
        rescue File::NotFoundError
          puts " Shards   NOT FOUND (shards not on PATH)"
        rescue ex
          Log.warn(exception: ex) { "Failed to detect shards version" }
        end

        # :nodoc:
        private def project_info
          return unless File.exists?("crystkit.json")

          puts ""
          puts "─" * 50
          puts " Project  #{Dir.current}/crystkit.json"

          begin
            cfg = Config.load_or_default
            puts " Name     #{cfg.package.name}"
            puts " Version  #{cfg.package.version}"
            puts " Ident    #{cfg.package.identifier}"

            entry = begin
              Build.new(cfg).entry_point
            rescue ex
              Log.warn(exception: ex) { "Could not resolve entry point for info display" }
              nil
            end
            if entry
              puts " Entry    #{entry}"
            end
          rescue ex
            puts " Config   invalid — #{ex.message}"
          end
        end
      end

      # Implements `crystkit doctor` — verifies that the required toolchain
      # (Crystal, shards, webview, git) is installed and that the local
      # `crystkit.json` (if any) parses.
      #
      # Never raises; missing tools are reported as issues with install
      # hints.
      class Doctor
        # Runs all health checks and prints the report to stdout.
        def run
          issues = [] of String
          fixes = [] of String

          unless check_crystal
            issues << "Crystal compiler not found"
            fixes << "Install Crystal: https://crystal-lang.org/install"
          end

          unless check_shards
            issues << "Shards package manager not found"
            fixes << "Install Crystal (includes shards): https://crystal-lang.org/install"
          end

          unless check_webview
            issues << "Webview library not found"
            {% if flag?(:linux) %}
              fixes << "Install: sudo apt install libwebkit2gtk-4.1-dev"
            {% else %}
              fixes << "Webview should be built-in on this platform"
            {% end %}
          end

          unless check_git
            issues << "Git not found"
            fixes << "Install Git: https://git-scm.com/downloads"
          end

          check_config(issues, fixes)

          puts "─" * 50
          puts " CrystKit Doctor"
          puts "─" * 50

          if issues.empty?
            puts " All checks passed — system is ready."
            return
          end

          puts ""
          issues.each_with_index do |issue, i|
            puts " #{i + 1}. #{issue}"
            puts "    Fix: #{fixes[i]}"
          end
          puts ""
          puts " #{issues.size} issue(s) found."
        end

        # :nodoc:
        private def check_crystal : Bool
          Shell.capture("crystal", "--version").success
        rescue File::NotFoundError
          false
        rescue ex : IO::Error
          Log.warn(exception: ex) { "Unexpected error checking for crystal" }
          false
        end

        # :nodoc:
        private def check_shards : Bool
          Shell.capture("shards", "--version").success
        rescue File::NotFoundError
          false
        rescue ex : IO::Error
          Log.warn(exception: ex) { "Unexpected error checking for shards" }
          false
        end

        # :nodoc:
        private def check_webview : Bool
          {% if flag?(:darwin) %}
            true
          {% elsif flag?(:linux) %}
            Dir.glob("/usr/lib/**/libwebkit2gtk*").any? { |path| File.file?(path) }
          {% elsif flag?(:win32) %}
            true
          {% else %}
            false
          {% end %}
        end

        # :nodoc:
        private def check_git : Bool
          Shell.capture("git", "--version").success
        rescue File::NotFoundError
          false
        rescue ex : IO::Error
          Log.warn(exception: ex) { "Unexpected error checking for git" }
          false
        end

        # :nodoc:
        private def check_config(issues : Array(String), fixes : Array(String))
          return unless File.exists?("crystkit.json")
          begin
            Config.load_or_default
          rescue ex
            issues << "crystkit.json: #{ex.message}"
            fixes << "Fix the configuration error"
          end
        end
      end
    end
  end
end
