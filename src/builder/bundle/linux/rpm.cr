require "log"
require "file_utils"
require "../common"

module CrystKit::Builder::Bundle::Linux
  # Builds an RPM (`.rpm`) package from a compiled binary.
  #
  # The generated `.spec` declares the WebKitGTK/GTK/appindicator
  # runtime requirements. Raises on failure.
  class Rpm
    # :nodoc:
    Log = ::Log.for(self)

    # The project configuration supplying package metadata and bundle settings.
    getter config : Config
    # Path to the compiled binary to package.
    getter binary_path : String
    # Directory where the `.rpm` and staging dirs are written.
    getter output_dir : String
    # Staged sidecar directory, or `nil` when no sidecars were prepared.
    getter sidecar_dir : String?
    # Staged frontend resources directory, or `nil` when none were prepared.
    getter resources_dir : String?

    # Creates an RPM package generator.
    def initialize(@config : Config, @binary_path : String, @output_dir : String, @sidecar_dir = nil, @resources_dir = nil)
    end

    # Builds the `.rpm` package and returns its path.
    #
    # Raises on failure or if no `.rpm` is produced.
    def generate : String
      app_name = config.package.name
      version = config.package.version
      rpm_arch = {% if flag?(:aarch64) %} "aarch64" {% else %} "x86_64" {% end %}

      build_root = Path[output_dir] / "#{app_name}_rpm_build"
      spec_dir = build_root / "SPECS"
      build_dir = build_root / "BUILD"
      # NOTE: BUILDROOT path and output filename are hardcoded to x86_64.
      # rpmbuild derives BUILDROOT naming from the spec's BuildArch, so on
      # aarch64 Linux this would need to be `aarch64` to match. Fixing this
      # requires threading `rpm_arch` here AND updating the test fixture
      # (spec/builder/bundler_packaging_spec.cr) which fakes rpmbuild with
      # hardcoded x86_64 paths.
      src_dir = build_root / "BUILDROOT" / "#{app_name}-#{version}-1.x86_64"
      usr_bin = src_dir / "usr" / "bin"
      usr_share_app = src_dir / "usr" / "share" / "applications"

      Dir.mkdir_p(spec_dir.to_s)
      Dir.mkdir_p(build_dir.to_s)
      Dir.mkdir_p(usr_bin.to_s)
      Dir.mkdir_p(usr_share_app.to_s)

      File.copy(binary_path, (usr_bin / app_name).to_s)
      File.chmod((usr_bin / app_name).to_s, 0o755)
      Common.stage_capabilities(@output_dir, usr_bin.to_s)

      stage_resources(src_dir, app_name)

      Common.write_desktop_file(usr_share_app.to_s, app_name, config.bundle.category)

      icon_paths = config.bundle.icon.map { |i| config.resolve(i).to_s }
      icons_dir = src_dir / "usr" / "share" / "icons" / "hicolor"
      Common.copy_icons(icon_paths, icons_dir.to_s, app_name, naming: Common::Naming::Hicolor)
      has_icons = Common.any_files?(icons_dir)
      has_resources = Common.any_files?(src_dir / "usr" / "share" / app_name)

      spec_path = spec_dir / "#{app_name.downcase}.spec"
      write_spec(spec_path, app_name, version, rpm_arch, has_icons, has_resources)

      rpm_path = Path[output_dir] / "#{app_name.downcase}-#{version}-1.x86_64.rpm"
      err_io = IO::Memory.new

      result = Process.run("rpmbuild", [
        "--define", "_topdir #{build_root}",
        "--define", "_rpmdir #{Path[output_dir]}",
        "--define", "_rpmfilename #{File.basename(rpm_path)}",
        "-bb", spec_path.to_s,
      ], output: Process::Redirect::Close, error: err_io)

      FileUtils.rm_rf(build_root.to_s)

      unless result.success?
        raise "Failed to build .rpm: #{err_io}"
      end

      unless File.exists?(rpm_path.to_s)
        raise "rpmbuild completed but no .rpm was found at #{rpm_path}"
      end

      Log.info { "Created .rpm at #{rpm_path}" }
      rpm_path.to_s
    end

    # :nodoc:
    private def stage_resources(src_dir : Path, app_name : String) : Nil
      Common.stage_resource_tree(@resources_dir, @sidecar_dir, src_dir / "usr" / "share" / app_name)
    end

    # :nodoc:
    private def write_spec(spec_path : Path, app_name : String, version : String, rpm_arch : String, has_icons : Bool, has_resources : Bool) : Nil
      resource_files = has_resources ? "/usr/share/#{app_name}\n" : ""
      icon_files = has_icons ? <<-SPEC : ""
%dir /usr/share/icons/hicolor
%dir /usr/share/icons/hicolor/*/apps
/usr/share/icons/hicolor/*/apps/#{app_name.downcase}.png
SPEC
      spec = <<-SPEC
Name: #{app_name.downcase}
Version: #{version}
Release: 1
Summary: #{config.package.description_or_default.gsub('\n', ' ')}
License: #{config.package.license || "MIT"}
URL: #{config.package.homepage || "https://crystkit.dev"}
BuildArch: #{rpm_arch}

Requires: webkit2gtk4.1, gtk3, libappindicator-gtk3

%description
#{app_name} - #{config.package.description_or_default.gsub('\n', ' ')}

%build

%install

%files
/usr/bin/#{app_name}
/usr/share/applications/#{app_name.downcase}.desktop
#{resource_files}#{icon_files}
SPEC
      File.write(spec_path.to_s, spec)
    end
  end
end
