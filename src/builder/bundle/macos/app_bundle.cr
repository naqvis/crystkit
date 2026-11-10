require "json"
require "log"
require "file_utils"
require "../common"

module CrystKit
  module Builder
    module Bundle
      module MacOS
        # Assembles a macOS `.app` bundle from a compiled binary, ready for
        # `DMG` packaging or direct code signing.
        class AppBundle
          # :nodoc:
          Log = ::Log.for(self)

          # The project configuration supplying package metadata and bundle settings.
          getter config : Config
          # Path to the compiled binary to package.
          getter binary_path : String
          # Directory where the `.app` bundle is written.
          getter output_dir : String
          # Staged sidecar directory, or `nil` when no sidecars were prepared.
          getter sidecar_dir : String?
          # Staged frontend resources directory, or `nil` when none were prepared.
          getter resources_dir : String?

          # Creates an AppBundle generator.
          def initialize(@config : Config, @binary_path : String, @output_dir : String, @sidecar_dir = nil, @resources_dir = nil)
          end

          # Generates the `.app` bundle and returns its path.
          #
          # Any existing bundle at the target path is removed first.
          def generate : String
            app_name = config.package.name
            bundle_id = config.package.identifier
            version = config.package.version

            app_dir = Path[output_dir] / "#{app_name}.app"
            contents_dir = app_dir / "Contents"
            macos_dir = contents_dir / "MacOS"
            resources = contents_dir / "Resources"

            FileUtils.rm_rf(app_dir.to_s)
            Dir.mkdir_p(macos_dir.to_s)
            Dir.mkdir_p(resources.to_s)

            File.copy(binary_path, (macos_dir / app_name).to_s)
            File.chmod((macos_dir / app_name).to_s, 0o755)
            Common.stage_capabilities(@output_dir, macos_dir.to_s)

            copy_sidecars(resources)
            copy_frontend_assets(resources)
            write_info_plist(contents_dir, app_name, bundle_id, version)
            write_pkg_info(contents_dir)
            copy_icons(resources, app_name)

            Log.info { "Created .app bundle at #{app_dir}" }
            app_dir.to_s
          end

          # :nodoc:
          private def write_info_plist(contents_dir : Path, app_name : String, bundle_id : String, version : String) : Nil
            safe_name = xml_escape(app_name)
            safe_bundle_id = xml_escape(bundle_id)
            safe_version = xml_escape(version)
            privacy_descriptions = String.build do |io|
              if description = config.bundle.macos_microphone_usage_description
                io << "  <key>NSMicrophoneUsageDescription</key>\n"
                io << "  <string>#{xml_escape(description)}</string>\n"
              end
              if description = config.bundle.macos_speech_recognition_usage_description
                io << "  <key>NSSpeechRecognitionUsageDescription</key>\n"
                io << "  <string>#{xml_escape(description)}</string>\n"
              end
            end
            plist = <<-XML
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>CFBundleDevelopmentRegion</key>
              <string>en</string>
              <key>CFBundleDisplayName</key>
              <string>#{safe_name}</string>
              <key>CFBundleExecutable</key>
              <string>#{safe_name}</string>
              <key>CFBundleIconFile</key>
              <string>#{safe_name}</string>
              <key>CFBundleIdentifier</key>
              <string>#{safe_bundle_id}</string>
              <key>CFBundleInfoDictionaryVersion</key>
              <string>6.0</string>
              <key>CFBundleName</key>
              <string>#{safe_name}</string>
              <key>CFBundlePackageType</key>
              <string>APPL</string>
              <key>CFBundleShortVersionString</key>
              <string>#{safe_version}</string>
              <key>CFBundleVersion</key>
              <string>#{safe_version}</string>
              <key>LSApplicationCategoryType</key>
              <string>#{ls_category(config.bundle.category)}</string>
              <key>NSHumanReadableCopyright</key>
              <string>#{xml_escape(config.bundle.copyright)}</string>
            #{privacy_descriptions}
              <key>CFBundleSupportedPlatforms</key>
              <array>
                <string>MacOSX</string>
              </array>
              <key>LSMinimumSystemVersion</key>
              <string>11.0</string>
              <key>NSHighResolutionCapable</key>
              <true/>
              <key>NSPrincipalClass</key>
              <string>NSApplication</string>
            </dict>
            </plist>
            XML

            File.write((contents_dir / "Info.plist").to_s, plist)
          end

          # Square pixel sizes accepted by `iconutil` when building an `.icns`.
          VALID_ICONUTIL_SIZES = [16, 32, 64, 128, 256, 512, 1024]

          # :nodoc:
          private def png_square_size(path : String) : Int32?
            File.open(path, "r") do |file|
              signature = Bytes.new(8)
              file.read_fully(signature)
              return nil unless signature == Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

              # Skip IHDR length (4), read and verify chunk type, then read width and height.
              file.skip(4) # IHDR length
              type_bytes = Bytes.new(4)
              file.read_fully(type_bytes)
              return nil unless type_bytes == Bytes[0x49, 0x48, 0x44, 0x52] # "IHDR"
              width_bytes = Bytes.new(4)
              height_bytes = Bytes.new(4)
              file.read_fully(width_bytes)
              file.read_fully(height_bytes)
              width = IO::ByteFormat::BigEndian.decode(Int32, width_bytes)
              height = IO::ByteFormat::BigEndian.decode(Int32, height_bytes)
              return width if width == height && VALID_ICONUTIL_SIZES.includes?(width)
            end
            nil
          rescue
            nil
          end

          # :nodoc:
          private def ls_category(category : String) : String
            case category.downcase
            when "utility", "utilities" then "public.app-category.utilities"
            when "developer", "developertool", "development"
              "public.app-category.developer-tools"
            when "productivity"       then "public.app-category.productivity"
            when "graphics", "design" then "public.app-category.graphics-design"
            when "education"          then "public.app-category.education"
            when "business"           then "public.app-category.business"
            when "game", "games"      then "public.app-category.games"
            when "music", "audio"     then "public.app-category.music"
            when "video"              then "public.app-category.video"
            else                           "public.app-category.utilities"
            end
          end

          # :nodoc:
          private def xml_escape(s : String) : String
            s.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;")
          end

          # :nodoc:
          private def write_pkg_info(contents_dir : Path) : Nil
            File.write((contents_dir / "PkgInfo").to_s, "APPL????")
          end

          # :nodoc:
          private def copy_sidecars(resources : Path) : Nil
            Common.stage_resource_tree(nil, sidecar_dir, resources)
            Log.debug { "AppBundle: bundled sidecars" } if sidecar_dir
          end

          # :nodoc:
          private def copy_frontend_assets(resources : Path) : Nil
            Common.stage_resource_tree(resources_dir, nil, resources)
            Log.debug { "AppBundle: bundled frontend assets" } if resources_dir
          end

          # :nodoc:
          private def copy_icons(resources : Path, app_name : String) : Nil
            icon_paths = config.bundle.icon.map { |i| config.resolve(i).to_s }
            return if icon_paths.empty?

            icns_source = Common.find_icon_by_ext(icon_paths, ".icns")
            if icns_source
              File.copy(icns_source, (resources / "#{app_name}.icns").to_s)
              return
            end

            png_sources = icon_paths.select { |i| i.ends_with?(".png") && File.exists?(i) }
            return if png_sources.empty?

            icns_path = (resources / "#{app_name}.icns").to_s
            iconset_dir = resources / "#{app_name}.iconset"
            Dir.mkdir_p(iconset_dir.to_s)

            png_sources.each do |src|
              if size = png_square_size(src)
                File.copy(src, (iconset_dir / "icon_#{size}x#{size}.png").to_s)
              else
                Log.warn { "Icon #{src} is not a valid square iconutil size (16/32/64/128/256/512/1024); skipping." }
              end
            end

            if Dir.children(iconset_dir.to_s).empty?
              Log.warn { "No valid square PNG icons found; cannot build .icns." }
              FileUtils.rm_rf(iconset_dir.to_s)
              return
            end

            err_io = IO::Memory.new
            result = Process.run("iconutil", ["--convert", "icns", "--output", icns_path, iconset_dir.to_s],
              output: Process::Redirect::Close, error: err_io)

            FileUtils.rm_rf(iconset_dir.to_s)

            if result.success?
              Log.debug { "Created icns from iconset" }
            else
              Log.warn { "iconutil failed: #{err_io}. Icons will not be embedded." }
            end
          end
        end

        # Produces a read-only, zlib-compressed `.dmg` disk image from an
        # `.app` bundle.
        class DMG
          # :nodoc:
          Log = ::Log.for(self)

          # Path to the source `.app` bundle.
          getter app_bundle_path : String
          # Directory where the `.dmg` is written.
          getter output_dir : String
          # Volume name embedded in the DMG (also used as the filename).
          getter volume_name : String

          # Creates a DMG generator for *app_bundle_path*.
          def initialize(@app_bundle_path : String, @output_dir : String, @volume_name : String)
          end

          # Generates the `.dmg` and returns its path.
          #
          # Raises if either `hdiutil` invocation fails.
          def generate : String
            dmg_path = Path[output_dir] / "#{volume_name}.dmg"
            temp_dmg = Path[output_dir] / "#{volume_name}_temp.dmg"
            staging = Path[output_dir] / "#{volume_name}_dmg_staging"

            Dir.mkdir_p(output_dir)
            File.delete(dmg_path.to_s) if File.exists?(dmg_path.to_s)
            File.delete(temp_dmg.to_s) if File.exists?(temp_dmg.to_s)
            FileUtils.rm_rf(staging.to_s)

            Dir.mkdir_p(staging.to_s)
            staged_app = staging / File.basename(app_bundle_path)
            cp_result = Process.run("cp", ["-R", app_bundle_path, staged_app.to_s],
              output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
            unless cp_result.success?
              FileUtils.rm_rf(staging.to_s)
              raise "Failed to copy app bundle to staging"
            end
            File.symlink("/Applications", (staging / "Applications").to_s) rescue nil

            app_size_mb = estimate_size_mb(staging.to_s)
            err_io = IO::Memory.new
            unless Process.run("hdiutil", [
                     "create", "-size", "#{app_size_mb}m",
                     "-volname", volume_name,
                     "-srcfolder", staging.to_s,
                     "-format", "UDRW",
                     "-ov", temp_dmg.to_s,
                   ], output: Process::Redirect::Close, error: err_io).success?
              FileUtils.rm_rf(staging.to_s)
              File.delete(temp_dmg.to_s) if File.exists?(temp_dmg.to_s)
              raise "Failed to create temporary DMG: #{err_io}"
            end

            err_io = IO::Memory.new
            begin
              unless Process.run("hdiutil", [
                       "convert", temp_dmg.to_s,
                       "-format", "UDZO",
                       "-imagekey", "zlib-level=9",
                       "-o", dmg_path.to_s,
                     ], output: Process::Redirect::Close, error: err_io).success?
                raise "Failed to convert DMG: #{err_io}"
              end
            ensure
              File.delete(temp_dmg.to_s) if File.exists?(temp_dmg.to_s)
              FileUtils.rm_rf(staging.to_s)
            end

            Log.info { "Created DMG at #{dmg_path}" }
            dmg_path.to_s
          end

          # :nodoc:
          private def estimate_size_mb(dir : String) : Int32
            total = 0_u64
            Dir.glob("#{dir}/**/*").each do |file_path|
              if info = File.info?(file_path)
                total += info.size if info.file?
              end
            rescue File::NotFoundError | IO::Error
              # File removed or inaccessible between glob and stat.
            end
            mb = (total / 1_048_576).to_i + 20
            Math.max(mb, 50)
          end
        end
      end
    end
  end
end
