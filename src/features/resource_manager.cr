require "log"
require "../platform/host"

module CrystKit
  module Features
    # Resolves resource paths relative to the application's resource directory.
    #
    # In development this is the project root; in production, the executable
    # or app bundle. Tests may override the detected directory via
    # `resource_dir=`.
    class ResourceManager
      Log = ::Log.for(self)

      # Resolve *path* relative to the resource directory.
      #
      # Returns the joined path when the file exists there, otherwise *path*
      # unchanged.
      #
      # ```
      # icon = CrystKit::Features::ResourceManager.resolve("icons/app.png")
      # ```
      def self.resolve(path : String) : String
        base = resource_dir
        full = File.join(base, path)
        File.exists?(full) ? full : path
      end

      def self.resolve_dir(path : String) : String
        Path[resource_dir, path].to_s
      end

      # Returns the application resource directory.
      def self.resource_dir : String
        @@resource_dir ||= detect_resource_dir
      end

      # Set a custom resource directory (e.g., for testing).
      #
      # Overrides any previously detected directory.
      def self.resource_dir=(path : String)
        @@resource_dir = path
      end

      # :nodoc:
      private def self.detect_resource_dir : String
        if resources = Platform::Host.bundle_resource_dir
          return resources
        end

        # Fallback: look relative to the executable
        if exe = Process.executable_path
          dir = File.dirname(exe)
          app_name = File.basename(exe, File.extname(exe))
          # Check for common resource locations
          candidates = [
            File.join(dir, "..", "share", app_name),
            File.join(dir, "resources"),
            File.join(dir, "..", "Resources"),
            File.join(dir, "..", "share", "resources"),
          ]
          candidates.each do |candidate|
            return candidate if Dir.exists?(candidate)
          end
        end

        # Last resort: current working directory
        Dir.current
      end
    end
  end
end
