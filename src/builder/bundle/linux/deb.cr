require "log"
require "file_utils"
require "../common"

module CrystKit::Builder::Bundle::Linux
  # Builds a Debian (`.deb`) package from a compiled binary.
  #
  # The resulting `.deb` declares dependencies on the WebKitGTK, GTK,
  # and appindicator runtime libraries CrystKit apps require.
  class Deb
    # :nodoc:
    Log = ::Log.for(self)

    # The project configuration supplying package metadata and bundle settings.
    getter config : Config
    # Path to the compiled binary to package.
    getter binary_path : String
    # Directory where the `.deb` and staging dirs are written.
    getter output_dir : String
    # Staged sidecar directory, or `nil` when no sidecars were prepared.
    getter sidecar_dir : String?
    # Staged frontend resources directory, or `nil` when none were prepared.
    getter resources_dir : String?

    # Creates a Debian package generator.
    def initialize(@config : Config, @binary_path : String, @output_dir : String, @sidecar_dir = nil, @resources_dir = nil)
    end

    # Builds the `.deb` package and returns its path.
    #
    # Raises on failure.
    def generate : String
      app_name = config.package.name

      build_dir = Path[output_dir] / "#{app_name}_deb_build"
      debian_dir = build_dir / "DEBIAN"
      usr_bin = build_dir / "usr" / "bin"
      usr_share_app = build_dir / "usr" / "share" / "applications"

      Dir.mkdir_p(debian_dir.to_s)
      Dir.mkdir_p(usr_bin.to_s)
      Dir.mkdir_p(usr_share_app.to_s)

      File.copy(binary_path, (usr_bin / app_name).to_s)
      File.chmod((usr_bin / app_name).to_s, 0o755)
      Common.stage_capabilities(@output_dir, usr_bin.to_s)

      deb_arch = {% if flag?(:aarch64) %} "arm64" {% else %} "amd64" {% end %}

      stage_resources(build_dir, app_name)

      write_control(debian_dir, app_name, deb_arch)
      Common.write_desktop_file(usr_share_app.to_s, app_name, config.bundle.category)

      icon_paths = config.bundle.icon.map { |i| config.resolve(i).to_s }
      icons_dir = build_dir / "usr" / "share" / "icons" / "hicolor"
      Common.copy_icons(icon_paths, icons_dir.to_s, app_name, naming: Common::Naming::Hicolor)

      deb_path = Path[output_dir] / "#{app_name.downcase}_#{config.package.version}_#{deb_arch}.deb"
      err_io = IO::Memory.new
      result = Process.run("dpkg-deb", ["--build", build_dir.to_s, deb_path.to_s],
        output: Process::Redirect::Close, error: err_io)

      FileUtils.rm_rf(build_dir.to_s)

      unless result.success?
        raise "Failed to build .deb: #{err_io}"
      end

      Log.info { "Created .deb at #{deb_path}" }
      deb_path.to_s
    end

    # :nodoc:
    private def stage_resources(build_dir : Path, app_name : String) : Nil
      Common.stage_resource_tree(@resources_dir, @sidecar_dir, build_dir / "usr" / "share" / app_name)
    end

    # :nodoc:
    private def write_control(debian_dir : Path, app_name : String, deb_arch : String) : Nil
      control = <<-CONTROL
Package: #{app_name.downcase}
Version: #{config.package.version}
Section: utils
Priority: optional
Architecture: #{deb_arch}
Maintainer: #{(config.package.maintainer || "Unknown").gsub('\n', ' ')}
Depends: libwebkit2gtk-4.1-0, libgtk-3-0, libayatana-appindicator3-1
Description: #{config.package.description_or_default.gsub('\n', ' ')}
CONTROL
      File.write((debian_dir / "control").to_s, control)
    end
  end
end
