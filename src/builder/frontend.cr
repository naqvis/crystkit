require "log"
require "json"
require "./shell"

module CrystKit
  module Builder
    # Frontend toolchain detection and command synthesis.
    #
    # Detects which Node.js package manager a project uses and translates it
    # into the concrete `build`/`dev` shell commands the builder and dev
    # server run.
    module Frontend
      # :nodoc:
      Log = ::Log.for(self)

      # Supported Node.js package managers, plus `None` when no manager
      # is detectable.
      enum Manager
        Npm
        Yarn
        Pnpm
        Bun
        None
      end

      # Lockfile filename indicating a given manager is in use, keyed by
      # `Manager`. Checked first during detection.
      MANAGER_LOCK_FILES = {
        Manager::Npm  => "package-lock.json",
        Manager::Yarn => "yarn.lock",
        Manager::Pnpm => "pnpm-lock.yaml",
        Manager::Bun  => "bun.lockb",
      }

      # Executable name for each manager, used as a fallback when no
      # lockfile is present.
      MANAGER_EXECUTABLES = {
        Manager::Npm  => "npm",
        Manager::Yarn => "yarn",
        Manager::Pnpm => "pnpm",
        Manager::Bun  => "bun",
      }

      # Detects which package manager a project at *project_dir* uses.
      #
      # Lockfiles take precedence over `PATH` lookups. Returns
      # `Manager::None` when nothing is found.
      def self.detect(project_dir : String) : Manager
        MANAGER_LOCK_FILES.each do |manager, lockfile|
          if File.exists?(File.join(project_dir, lockfile))
            return manager
          end
        end

        MANAGER_EXECUTABLES.each do |manager, executable|
          return manager if Shell.which?(executable)
        end

        Log.debug { "No frontend package manager detected in #{project_dir}" }
        Manager::None
      end

      # Returns `true` when *project_dir* contains a `package.json`.
      def self.has_package_json?(project_dir : String) : Bool
        File.exists?(File.join(project_dir, "package.json"))
      end

      # Synthesizes the frontend `build` command for *project_dir*, or
      # returns `nil`.
      #
      # Returns `nil` when there is no `package.json`, no `build` script,
      # or no detectable manager.
      def self.detect_build_command(project_dir : String) : String?
        pkg_path = File.join(project_dir, "package.json")
        return nil unless File.exists?(pkg_path)

        begin
          pkg = JSON.parse(File.read(pkg_path))
          scripts = pkg["scripts"]?.try(&.as_h) || {} of String => JSON::Any
          return nil unless scripts.has_key?("build")
        rescue
          return nil
        end

        manager = detect(project_dir)
        case manager
        when Manager::Npm  then "npm run build"
        when Manager::Yarn then "yarn build"
        when Manager::Pnpm then "pnpm run build"
        when Manager::Bun  then "bun run build"
        else                    nil
        end
      end

      # Synthesizes the frontend `dev` command for *project_dir*, or
      # returns `nil`.
      #
      # Returns `nil` when there is no `package.json`, no `dev` script, or
      # no detectable manager.
      def self.detect_dev_command(project_dir : String) : String?
        pkg_path = File.join(project_dir, "package.json")
        return nil unless File.exists?(pkg_path)

        begin
          pkg = JSON.parse(File.read(pkg_path))
          scripts = pkg["scripts"]?.try(&.as_h) || {} of String => JSON::Any
          return nil unless scripts.has_key?("dev")
        rescue
          return nil
        end

        manager = detect(project_dir)
        case manager
        when Manager::Npm  then "npm run dev"
        when Manager::Yarn then "yarn dev"
        when Manager::Pnpm then "pnpm run dev"
        when Manager::Bun  then "bun run dev"
        else                    nil
        end
      end
    end
  end
end
