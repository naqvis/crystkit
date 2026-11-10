require "../base"
require "../../features/system_info"

module CrystKit
  module Plugins
    # Builtin plugin that exposes read-only host and application environment
    # information to the frontend.
    #
    # Surfaces OS, architecture, hostname, CPU, memory, disk, network
    # interfaces, displays, locale, app build metadata, standard data
    # directories, and the user's home directory. All commands share a single
    # `system:read` capability and return plain JSON objects/strings.
    #
    # Registers IPC commands:
    #   system_info:os, system_info:arch, system_info:hostname,
    #   system_info:cpu, system_info:memory, system_info:disk,
    #   system_info:network, system_info:displays, system_info:locale,
    #   system_info:app, system_info:app_data_dirs, system_info:home_dir
    #
    # Required capability: `system:read`
    #
    # ```
    # app.plugin(CrystKit::Plugins::SystemInfo.new)
    # ```
    class SystemInfo < Plugin::Base
      # The system-info feature, lazily initialized during `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! info

      # Returns the unique plugin identifier `"system_info"`.
      def identifier : String
        "system_info"
      end

      # Returns the metadata contract gating every command behind the
      # `system:read` capability.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(system_info.os system_info.arch system_info.hostname system_info.cpu system_info.memory system_info.disk system_info.network system_info.displays system_info.locale system_info.app system_info.app_data_dirs system_info.home_dir), "system:read")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(system:read),
          commands: %w(system_info.os system_info.arch system_info.hostname system_info.cpu system_info.memory system_info.disk system_info.network system_info.displays system_info.locale system_info.app system_info.app_data_dirs system_info.home_dir),
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # Most commands take no arguments and return a flat JSON object of the
      # relevant fields. `system_info.disk` is the exception: it takes a mount
      # path (defaulting to `"/"` when empty) and returns total, available, and
      # used bytes for that location.
      def initialize_plugin(context : Plugin::Context) : Nil
        @info = info = Features::SystemInfo.new

        context.command "system_info.os" do
          os = info.os_info
          {"name" => os.name, "version" => os.version}
        end

        context.command "system_info.arch" do
          info.architecture.to_s
        end

        context.command "system_info.hostname" do
          info.hostname
        end

        context.command "system_info.cpu" do
          c = info.cpu_info
          {"model" => c.model, "cores" => c.cores, "frequency" => c.frequency_ghz}
        end

        context.command "system_info.memory" do
          m = info.memory_info
          {"total" => m.total, "available" => m.available, "used" => m.used}
        end

        # Disk usage for a given mount/path (defaults to "/").
        context.command "system_info.disk", String do |path|
          d = info.disk_info(path.empty? ? "/" : path)
          {"total" => d.total, "available" => d.available, "used" => d.used}
        end

        # Active network interfaces with IP and MAC addresses.
        context.command "system_info.network" do
          info.network_interfaces.map do |iface|
            {"name" => iface.name, "ip_address" => iface.address, "mac_address" => iface.mac_address}
          end
        end

        # Connected displays with resolution and scale factor.
        context.command "system_info.displays" do
          info.display_info.map do |display|
            {
              "id"           => display.id,
              "width"        => display.width,
              "height"       => display.height,
              "scale_factor" => display.scale_factor,
              "primary"      => display.primary?,
            }
          end
        end

        # Locale and language information.
        context.command "system_info.locale" do
          l = info.locale_info
          {"locale" => l.name, "language" => l.language}
        end

        # Application version and build information.
        context.command "system_info.app" do
          a = info.app_info
          {"version" => a.version, "build" => a.build, "build_time" => a.build_time}
        end

        # Standard application data directories for this platform/user.
        context.command "system_info.app_data_dirs" do
          dirs = info.app_data_directories
          {
            "data"        => dirs.data,
            "config"      => dirs.config,
            "cache"       => dirs.cache,
            "system_data" => dirs.system_data,
          }
        end

        context.command "system_info.home_dir" do
          info.home_directory
        end
      end
    end
  end
end
