require "log"
require "file_utils"
require "../common"

module CrystKit
  module Builder
    module Bundle
      module Linux
        # Builds a self-contained `.AppImage` from a compiled binary.
        #
        # AppImages are single-file, relocatable Linux applications that
        # run without installation. Raises if `appimagetool` is missing or
        # fails.
        class AppImage
          # :nodoc:
          Log = ::Log.for(self)

          # Shell launcher placed at the AppDir root. The `APP_BINARY`
          # placeholder is replaced with the app name at generation time.
          APPRUN_SCRIPT = <<-'SH'
#!/bin/sh
HERE="$(dirname "$(readlink -f "${0}")")"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${LD_LIBRARY_PATH}"
export PATH="${HERE}/usr/bin:${PATH}"
exec "${HERE}/usr/bin/APP_BINARY" "$@"
SH

          # The project configuration supplying package metadata and bundle settings.
          getter config : Config
          # Path to the compiled binary to package.
          getter binary_path : String
          # Directory where the AppImage and staging dirs are written.
          getter output_dir : String
          # Staged sidecar directory, or `nil` when no sidecars were prepared.
          getter sidecar_dir : String?
          # Staged frontend resources directory, or `nil` when none were prepared.
          getter resources_dir : String?

          # Creates an AppImage generator.
          def initialize(@config : Config, @binary_path : String, @output_dir : String, @sidecar_dir = nil, @resources_dir = nil)
          end

          # Builds the AppImage and returns its path.
          def generate : String
            app_name = config.package.name

            appdir = Path[output_dir] / "#{app_name}.AppDir"
            usr_bin = appdir / "usr" / "bin"

            usr_lib = appdir / "usr" / "lib"

            Dir.mkdir_p(usr_bin.to_s)
            Dir.mkdir_p(usr_lib.to_s)

            File.copy(binary_path, (usr_bin / app_name).to_s)
            File.chmod((usr_bin / app_name).to_s, 0o755)
            Common.stage_capabilities(@output_dir, usr_bin.to_s)

            bundle_system_libs(binary_path, usr_lib)

            apprun = APPRUN_SCRIPT.gsub("APP_BINARY", app_name)
            File.write((appdir / "AppRun").to_s, apprun)
            File.chmod((appdir / "AppRun").to_s, 0o755)

            Common.write_desktop_file(appdir.to_s, app_name, config.bundle.category)

            stage_resources(appdir, app_name)

            icon_paths = config.bundle.icon.map { |i| config.resolve(i).to_s }
            if icon_src = Common.first_existing_icon(icon_paths)
              ext = File.extname(icon_src)
              File.copy(icon_src, (appdir / "#{app_name.downcase}#{ext}").to_s)
            end

            appimage_path = Path[output_dir] / "#{app_name.downcase}-#{config.package.version}-x86_64.AppImage"
            err_io = IO::Memory.new
            result = Process.run("appimagetool", [appdir.to_s, appimage_path.to_s],
              output: Process::Redirect::Close, error: err_io)

            unless result.success?
              FileUtils.rm_rf(appimage_path.to_s) if File.exists?(appimage_path.to_s)
              FileUtils.rm_rf(appdir.to_s)
              raise "Failed to create AppImage. Is appimagetool installed? (#{err_io.to_s.strip})"
            end

            FileUtils.rm_rf(appdir.to_s)

            Log.info { "Created AppImage at #{appimage_path}" }
            appimage_path.to_s
          end

          # Filesystem prefixes identifying system libraries worth bundling.
          SYSTEM_LIB_PREFIXES = ["/usr/lib", "/lib"]
          # Library name prefixes excluded from bundling (expected on every
          # glibc-based Linux system).
          EXCLUDED_LIBS = ["ld-linux", "libc.so", "libdl.so", "libpthread.so",
                           "librt.so", "libm.so", "libcrypt.so", "libresolv.so",
                           "libutil.so", "libnsl.so", "libnss_"]

          # :nodoc:
          private def bundle_system_libs(binary : String, target_lib_dir : Path) : Nil
            Log.info { "AppImage: discovering shared library dependencies..." }
            ldd_output = IO::Memory.new
            result = Process.run("ldd", [binary], output: ldd_output, error: Process::Redirect::Close)
            return unless result.success?

            ldd_output.to_s.each_line do |line|
              if line =~ /^\s+(\S+)\s+=>\s+(\/\S+)\s/
                lib_path = $2
                lib_name = File.basename(lib_path)
                next if EXCLUDED_LIBS.any? { |excl| lib_name.starts_with?(excl) }
                next unless SYSTEM_LIB_PREFIXES.any? { |prefix| lib_path.starts_with?(prefix) }
                next unless File.exists?(lib_path)

                dest = (target_lib_dir / lib_name).to_s
                next if File.exists?(dest)
                File.copy(lib_path, dest)
                Log.debug { "AppImage: bundled #{lib_name}" }
              end
            end
          rescue ex
            Log.warn { "AppImage: library bundling failed: #{ex.message}" }
          end

          # :nodoc:
          private def stage_resources(appdir : Path, app_name : String) : Nil
            Common.stage_resource_tree(@resources_dir, @sidecar_dir, appdir / "usr" / "share" / app_name)
          end
        end
      end
    end
  end
end
