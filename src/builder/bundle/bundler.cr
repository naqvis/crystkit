require "log"
require "file_utils"
require "../../features/sidecar"
require "./common"
require "./pak_builder"

module CrystKit
  module Builder
    # Packaging subsystem that turns a compiled binary into a distributable
    # installer or portable bundle for the host platform.
    module Bundle
      # Drives the production of one or more distributable packages from a
      # pre-built binary.
      #
      # Invoked after `Build#run` (or directly by `crystkit bundle` when the
      # binary already exists). Each requested target is dispatched to its
      # platform-specific generator (`MacOS::AppBundle`, `Linux::Deb`,
      # `Linux::Rpm`, `Linux::AppImage`, `Windows::Msi`, `Windows::Nsis`).
      # Targets unsupported on the current host platform, or unknown
      # targets, are skipped with a warning rather than aborting the run.
      #
      # ```
      # bundler = CrystKit::Builder::Bundle::Bundler.new(cfg, binary_path, "./dist")
      # results = bundler.bundle(["dmg", "deb"])
      # results.each { |target, path| puts "#{target}: #{path}" }
      # ```
      class Bundler
        # :nodoc:
        Log = ::Log.for(self)

        # Target name aliases accepted for macOS packages.
        MACOS_TARGETS = %w[dmg app macos osx]
        # Target name aliases accepted for Linux packages.
        LINUX_TARGETS = %w[deb rpm appimage]
        # Target name aliases accepted for Windows packages.
        WINDOWS_TARGETS = %w[msi nsis exe windows]
        # Union of all recognized target aliases plus `portable`.
        KNOWN_TARGETS = MACOS_TARGETS + LINUX_TARGETS + WINDOWS_TARGETS + %w[portable]

        # The project configuration supplying package metadata and bundle settings.
        getter config : Config

        # Path to the compiled binary to package.
        getter binary_path : String

        # Directory where bundle artifacts and staging directories are written.
        getter output_dir : String

        # Creates a bundler for *binary_path* described by *config*.
        def initialize(@config : Config, @binary_path : String, @output_dir = "./dist")
        end

        # Produces packages for the given *targets*, returning a map of target
        # name to artifact path.
        #
        # When *targets* is `nil`, `bundle.targets` from the config is used.
        # Per-target failures are collected and re-raised together at the
        # end. The returned hash only contains entries for targets that
        # were successfully built.
        def bundle(targets : Array(String)? = nil) : Hash(String, String)
          targets ||= config.bundle.targets
          results = {} of String => String
          failures = [] of String

          if targets.empty?
            Log.warn { "No bundle targets specified. Use --target or set bundle.targets in crystkit.json." }
            return results
          end

          unless File.exists?(binary_path)
            raise "Binary not found at '#{binary_path}'. Run `crystkit build` first, or pass --binary."
          end

          Dir.mkdir_p(output_dir)

          sidecar_dir = copy_sidecars
          resources_dir = stage_resources
          stage_capabilities_manifest(output_dir)

          targets.each do |target|
            key = target.downcase

            unless KNOWN_TARGETS.includes?(key)
              failures << "Unknown bundle target: #{target}."
              next
            end

            unless can_build?(key)
              Log.warn { "Cannot build '#{target}' on #{host_os}; skipping." }
              next
            end

            begin
              case key
              when "dmg", "macos", "osx", "app" then results["dmg"] = bundle_macos(sidecar_dir, resources_dir)
              when "deb"                        then results["deb"] = bundle_linux_deb(sidecar_dir, resources_dir)
              when "rpm"                        then results["rpm"] = bundle_linux_rpm(sidecar_dir, resources_dir)
              when "appimage"                   then results["appimage"] = bundle_linux_appimage(sidecar_dir, resources_dir)
              when "msi", "windows"             then results["msi"] = bundle_windows_msi(sidecar_dir, resources_dir)
              when "nsis", "exe"                then results["nsis"] = bundle_windows_nsis(sidecar_dir, resources_dir)
              when "portable"                   then results["portable"] = bundle_portable(sidecar_dir, resources_dir)
              end
            rescue ex
              failures << "Failed to build '#{target}': #{ex.message}"
            end
          end

          unless failures.empty?
            failures.each { |message| Log.error { message } }
            raise failures.join("\n")
          end

          results
        end

        # :nodoc:
        private def host_os : String
          {% if flag?(:darwin) %}
            "macOS"
          {% elsif flag?(:linux) %}
            "Linux"
          {% elsif flag?(:windows) %}
            "Windows"
          {% else %}
            "this platform"
          {% end %}
        end

        # :nodoc:
        private def can_build?(target : String) : Bool
          return true if target == "portable"
          {% if flag?(:darwin) %}
            MACOS_TARGETS.includes?(target)
          {% elsif flag?(:linux) %}
            LINUX_TARGETS.includes?(target)
          {% elsif flag?(:windows) %}
            WINDOWS_TARGETS.includes?(target)
          {% else %}
            false
          {% end %}
        end

        # :nodoc:
        private def stage_resources : String
          dist = config.build.frontend_dist
          src = config.resolve(dist)
          unless Dir.exists?(src.to_s)
            Log.debug { "Bundler: no frontend assets at #{src}; skipping resource staging." }
            return ""
          end

          dest = (Path[output_dir] / "resources").to_s
          src_exp = File.expand_path(src.to_s)
          dest_exp = File.expand_path(dest)
          if src_exp == dest_exp || dest_exp.starts_with?(src_exp + File::SEPARATOR)
            Log.debug { "Bundler: frontend dist overlaps with bundle resources dir; skipping." }
            return ""
          end

          FileUtils.rm_rf(dest)
          Dir.mkdir_p(dest)

          if config.bundle.pak.enabled?
            pak_path = File.join(dest, "assets.vpak")
            PakBuilder.build(src.to_s, pak_path,
              compress: config.bundle.pak.codec_symbol,
              chunk_size: config.bundle.pak.chunk_size_bytes,
              package_id: config.package.identifier)
            Log.info { "Staged frontend assets as #{pak_path}." }
          else
            Common.copy_tree(src.to_s, dest)
            Log.info { "Staged frontend assets (loose files) from #{src}." }
          end

          dest
        end

        # Copies `capabilities.json` into *output_dir* so each platform
        # bundler can stage it beside the binary.
        # :nodoc:
        private def stage_capabilities_manifest(output_dir : String) : Nil
          manifest_path = config.app.security.capabilities_manifest
          return unless manifest_path && !manifest_path.empty?

          src = config.resolve(manifest_path)
          return unless File.exists?(src.to_s)

          dest = File.join(output_dir, "capabilities.json")
          File.copy(src.to_s, dest)
          Log.info { "Staged capabilities manifest at #{dest}." }
        end

        # :nodoc:
        private def copy_sidecars : String
          return "" if config.bundle.external_bin.empty?

          sidecar_dir = Path[output_dir] / "sidecars"
          Dir.mkdir_p(sidecar_dir.to_s)

          config.bundle.external_bin.each do |bin|
            base = config.resolve(bin.path)
            src_path = base / bin.name

            if Dir.exists?(base.to_s)
              Dir.children(base.to_s).each do |entry|
                next unless entry.starts_with?(bin.name)
                full_src = File.join(base.to_s, entry)
                next unless File.file?(full_src) && File::Info.executable?(full_src)

                File.copy(full_src, (sidecar_dir / entry).to_s)
                File.chmod((sidecar_dir / entry).to_s, 0o755)
                Log.debug { "Bundler: copied sidecar #{entry}" }
              end
            end

            ext = {% if flag?(:win32) %} ".exe" {% else %} "" {% end %}
            base_src = "#{src_path}#{ext}"
            if File.exists?(base_src)
              triple = CrystKit::Features::TargetTriple.current
              triple_name = "#{bin.name}-#{triple}#{ext}"
              File.copy(base_src, (sidecar_dir / triple_name).to_s)
              File.chmod((sidecar_dir / triple_name).to_s, 0o755)
              Log.debug { "Bundler: copied sidecar #{triple_name}" }
            end
          end

          sidecar_dir.to_s
        end

        # :nodoc:
        private def bundle_macos(sidecar_dir : String, resources_dir : String) : String
          {% if flag?(:darwin) %}
            app_bundle = MacOS::AppBundle.new(config, binary_path, output_dir,
              sidecar_dir: sidecar_dir, resources_dir: resources_dir)
            app_path = app_bundle.generate

            if signing = config.bundle.signing
              if mac_identity = signing.macos
                signer = MacOS::CodeSign.new(mac_identity.identity, mac_identity.entitlements_path)
                unless signer.sign(app_path)
                  raise "Code signing failed for #{app_path}"
                end

                if ENV["AC_USERNAME"]? && ENV["AC_TEAM_ID"]? && ENV["AC_PASSWORD"]?
                  signer.notarize(app_path, config.package.identifier)
                  signer.staple(app_path)
                end
              end
            end

            dmg = MacOS::DMG.new(app_path, output_dir, config.package.name)
            dmg.generate
          {% else %}
            Log.warn { "Cannot build macOS bundle on non-macOS platform." }
            ""
          {% end %}
        end

        # :nodoc:
        private def bundle_linux_rpm(sidecar_dir : String, resources_dir : String) : String
          {% if flag?(:linux) %}
            Linux::Rpm.new(config, binary_path, output_dir,
              sidecar_dir: sidecar_dir, resources_dir: resources_dir).generate
          {% else %}
            Log.warn { "Cannot build .rpm on non-Linux platform." }
            ""
          {% end %}
        end

        # :nodoc:
        private def bundle_linux_deb(sidecar_dir : String, resources_dir : String) : String
          {% if flag?(:linux) %}
            Linux::Deb.new(config, binary_path, output_dir,
              sidecar_dir: sidecar_dir, resources_dir: resources_dir).generate
          {% else %}
            Log.warn { "Cannot build .deb on non-Linux platform." }
            ""
          {% end %}
        end

        # :nodoc:
        private def bundle_linux_appimage(sidecar_dir : String, resources_dir : String) : String
          {% if flag?(:linux) %}
            Linux::AppImage.new(config, binary_path, output_dir,
              sidecar_dir: sidecar_dir, resources_dir: resources_dir).generate
          {% else %}
            Log.warn { "Cannot build AppImage on non-Linux platform." }
            ""
          {% end %}
        end

        # :nodoc:
        private def bundle_windows_nsis(sidecar_dir : String, resources_dir : String) : String
          {% if flag?(:windows) %}
            Windows::Nsis.new(config, binary_path, output_dir,
              sidecar_dir: sidecar_dir, resources_dir: resources_dir).generate
          {% else %}
            Log.warn { "Cannot build NSIS installer on non-Windows platform." }
            ""
          {% end %}
        end

        # :nodoc:
        private def bundle_windows_msi(sidecar_dir : String, resources_dir : String) : String
          {% if flag?(:windows) %}
            msi = Windows::Msi.new(config, binary_path, output_dir,
              sidecar_dir: sidecar_dir, resources_dir: resources_dir)
            path = msi.generate

            if signing = config.bundle.signing
              if win_sign = signing.windows
                Windows::Sign.new(win_sign.certificate_path, win_sign.password_env).sign(path)
              end
            end

            path
          {% else %}
            Log.warn { "Cannot build .msi on non-Windows platform." }
            ""
          {% end %}
        end

        # :nodoc:
        private def bundle_portable(sidecar_dir : String, resources_dir : String) : String
          ext = {% if flag?(:win32) %} ".exe" {% else %} "" {% end %}
          name = config.package.name.gsub(/[^A-Za-z0-9_.-]/, "_")
          portable_dir = Path[output_dir] / "#{name}-portable"
          FileUtils.rm_rf(portable_dir.to_s)
          Dir.mkdir_p(portable_dir.to_s)

          File.copy(binary_path, (portable_dir / "#{name}#{ext}").to_s)
          File.chmod((portable_dir / "#{name}#{ext}").to_s, 0o755)
          Common.stage_capabilities(output_dir, portable_dir.to_s)

          Common.stage_resource_tree(
            resources_dir.empty? ? nil : resources_dir,
            sidecar_dir.empty? ? nil : sidecar_dir,
            portable_dir / "resources"
          )

          Log.info { "Created portable bundle at #{portable_dir}" }
          portable_dir.to_s
        end
      end
    end
  end
end

require "./macos/app_bundle"
require "./macos/signing"
require "./linux/deb"
require "./linux/rpm"
require "./linux/appimage"
require "./windows/msi"
require "./windows/nsis"
