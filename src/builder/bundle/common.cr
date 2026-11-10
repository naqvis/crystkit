require "log"
require "file_utils"

module CrystKit
  module Builder
    module Bundle
      # Shared helpers used by every platform bundler.
      #
      # Provides recursive directory copying, resource/sidecar staging,
      # icon handling, `.desktop` file generation, and XML/identifier
      # sanitization.
      module Common
        # :nodoc:
        Log = ::Log.for(self)

        # Recursively copies the directory tree at *src* into *dest*.
        #
        # Refuses to copy when *dest* is inside *src* (or equal to it) to
        # avoid recursive self-copy, logging a warning and returning
        # instead. *dest* is created on demand.
        def self.copy_tree(src : String, dest : String) : Nil
          src_exp = File.expand_path(src)
          dest_exp = File.expand_path(dest)
          if dest_exp.starts_with?(src_exp + File::SEPARATOR) || src_exp == dest_exp
            Log.warn { "copy_tree skipped: destination is inside source (#{src} → #{dest})" }
            return
          end
          Dir.mkdir_p(dest)
          Dir.each_child(src) do |entry|
            s = File.join(src, entry)
            d = File.join(dest, entry)
            if File.symlink?(s)
              # Copy the symlink target's content, not the symlink itself,
              # to avoid infinite recursion on circular symlinks.
              File.copy(s, d)
            elsif File.directory?(s)
              copy_tree(s, d)
            else
              File.copy(s, d)
            end
          end
        end

        # Stages frontend assets and sidecar binaries under *dest_root*.
        #
        # Frontend assets (when *resources_dir* exists) are copied directly
        # into *dest_root*; sidecar binaries (when *sidecar_dir* exists)
        # are copied into `dest_root/sidecars` and made executable. Either
        # argument may be `nil` to skip that portion.
        def self.stage_resource_tree(resources_dir : String?, sidecar_dir : String?, dest_root : String | Path) : Nil
          root = dest_root.to_s

          if resources_dir && Dir.exists?(resources_dir)
            Dir.mkdir_p(root)
            copy_tree(resources_dir, root)
          end

          if sidecar_dir && Dir.exists?(sidecar_dir)
            dest = File.join(root, "sidecars")
            Dir.mkdir_p(dest)
            Dir.children(sidecar_dir).each do |entry|
              src = File.join(sidecar_dir, entry)
              next unless File.file?(src)

              output_path = File.join(dest, entry)
              File.copy(src, output_path)
              File.chmod(output_path, 0o755)
            end
          end
        end

        # Copies `capabilities.json` from *src_dir* to *dest_dir*, when
        # present in *src_dir*. Intended for staging beside the binary.
        def self.stage_capabilities(src_dir : String, dest_dir : String) : Nil
          src = File.join(src_dir, "capabilities.json")
          return unless File.exists?(src)

          dest = File.join(dest_dir, "capabilities.json")
          File.copy(src, dest)
          Log.debug { "Staged capabilities manifest at #{dest}" }
        end

        # Returns `true` if *dir* contains at least one regular file,
        # searching recursively.
        def self.any_files?(dir : String | Path) : Bool
          return false unless Dir.exists?(dir.to_s)

          Dir.glob(File.join(dir.to_s, "**", "*")).each do |path|
            return true if File.file?(path)
          end
          false
        end

        # Escapes *s* for safe inclusion in XML text/attribute content.
        #
        # Replaces `&`, `<`, `>`, and `"` with their entity references.
        def self.xml_escape(s : String) : String
          s.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;").gsub('"', "&quot;")
        end

        # Derives a valid identifier from *s* for use in installer schemas.
        #
        # Non-alphanumeric characters become underscores and a leading
        # underscore is prepended when the result would otherwise start
        # with a digit.
        def self.identifier(s : String) : String
          id = s.gsub(/[^A-Za-z0-9_]/, "_")
          id = "_#{id}" unless id[0]?.try(&.ascii_letter?) || id.starts_with?("_")
          id
        end

        # Writes a freedesktop `.desktop` entry for *app_name* into *dir*,
        # tagged with *category*. Returns the path written.
        def self.write_desktop_file(dir : String, app_name : String, category : String) : String
          desktop = <<-DESKTOP
[Desktop Entry]
Type=Application
Name=#{app_name}
Exec=#{app_name}
Icon=#{app_name.downcase}
Terminal=false
Categories=#{category};
DESKTOP
          path = File.join(dir, "#{app_name.downcase}.desktop")
          File.write(path, desktop)
          path
        end

        # Copies square-dimensioned PNG icons from *icon_paths* into
        # *dest_root* using the requested *naming* convention.
        #
        # Only icons whose filename embeds a size (e.g. `128x128.png`)
        # are copied. `Naming::Hicolor` places them under the
        # `<size>x<size>/apps/` hicolor hierarchy; `Naming::Flat` and
        # `Naming::Infer` keep the original basename in *dest_root*.
        def self.copy_icons(icon_paths : Array(String), dest_root : String, app_name : String, naming : Naming = Naming::Infer) : Nil
          icon_paths.each do |icon_path|
            next unless File.exists?(icon_path)
            basename = File.basename(icon_path)

            if basename =~ /^(\d+)x\d+\./
              size = $1
              dest_path = case naming
                          when Naming::Hicolor
                            dir = File.join(dest_root, "#{size}x#{size}", "apps")
                            Dir.mkdir_p(dir)
                            File.join(dir, "#{app_name.downcase}.png")
                          when Naming::Flat
                            Dir.mkdir_p(dest_root)
                            File.join(dest_root, basename)
                          else
                            Dir.mkdir_p(dest_root)
                            File.join(dest_root, basename)
                          end
              File.copy(icon_path, dest_path)
            end
          end
        end

        # Returns the first icon path ending with *ext* that exists, or
        # `nil`.
        def self.find_icon_by_ext(icon_paths : Array(String), ext : String) : String?
          icon_paths.find { |i| i.ends_with?(ext) && File.exists?(i) }
        end

        # Returns the first icon path in *icon_paths* that exists on disk,
        # or `nil`.
        def self.first_existing_icon(icon_paths : Array(String)) : String?
          icon_paths.find { |i| File.exists?(i) }
        end

        # Icon placement strategy used by `copy_icons`.
        enum Naming
          Hicolor
          Flat
          Infer
        end
      end
    end
  end
end
