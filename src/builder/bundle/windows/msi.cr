require "log"
require "file_utils"
require "uuid"
require "digest"
require "../common"

module CrystKit
  module Builder
    module Bundle
      module Windows
        # Builds a Windows MSI installer from a compiled binary using the WiX
        # Toolset.
        class Msi
          # :nodoc:
          Log = ::Log.for(self)

          # The project configuration supplying package metadata and bundle settings.
          getter config : Config
          # Path to the compiled binary to package.
          getter binary_path : String
          # Directory where the `.msi` and staging dirs are written.
          getter output_dir : String
          # Staged sidecar directory, or `nil` when no sidecars were prepared.
          getter sidecar_dir : String?
          # Staged frontend resources directory, or `nil` when none were prepared.
          getter resources_dir : String?

          # Creates an MSI generator.
          def initialize(@config : Config, @binary_path : String, @output_dir : String, @sidecar_dir = nil, @resources_dir = nil)
          end

          # Builds the `.msi` installer and returns its path.
          #
          # Raises with a hint to install WiX if `candle` is missing.
          def generate : String
            app_name = config.package.name
            version = config.package.version
            upgrade_code = config.bundle.upgrade_code || UUID.new(Digest::SHA256.digest(config.package.identifier)[0, 16]).to_s.upcase

            work_dir = Path[output_dir] / "msi_work"
            Dir.mkdir_p(work_dir.to_s)

            File.copy(binary_path, (work_dir / "#{app_name}.exe").to_s)
            Common.stage_capabilities(@output_dir, work_dir.to_s)
            stage_resources(work_dir)

            wxs_path = write_wxs(work_dir, app_name, version, upgrade_code)

            wixobj_path = work_dir / "app.wixobj"
            out_io = IO::Memory.new
            err_io = IO::Memory.new
            result = Process.run("candle", [
              "-arch", "x64",
              "-out", wixobj_path.to_s,
              wxs_path,
            ], output: out_io, error: err_io)

            unless result.success?
              FileUtils.rm_rf(work_dir.to_s)
              raise "WiX candle failed: #{err_io}. Is WiX Toolset installed?"
            end

            msi_path = Path[output_dir] / "#{app_name}-#{version}.msi"
            out_io = IO::Memory.new
            err_io = IO::Memory.new
            result = Process.run("light", [
              "-out", msi_path.to_s,
              "-ext", "WixUIExtension",
              wixobj_path.to_s,
            ], output: out_io, error: err_io)

            FileUtils.rm_rf(work_dir.to_s)

            unless result.success?
              raise "WiX light failed: #{err_io}"
            end

            Log.info { "Created MSI at #{msi_path}" }
            msi_path.to_s
          end

          # :nodoc:
          private def write_wxs(work_dir : Path, app_name : String, version : String, upgrade_code : String) : String
            resource_directory, resource_refs = build_resource_directory(work_dir)

            capabilities_source = (work_dir / "capabilities.json").to_s
            has_capabilities = File.exists?(capabilities_source)
            safe_capabilities_source = Common.xml_escape(capabilities_source)

            safe_name = Common.xml_escape(app_name)
            safe_publisher = Common.xml_escape(config.package.publisher)
            safe_version = Common.xml_escape(version)
            safe_exe_source = Common.xml_escape((work_dir / "#{app_name}.exe").to_s)

            capabilities_ref = has_capabilities ? "      <ComponentRef Id=\"CapabilitiesComponent\" />\n" : ""
            capabilities_component = has_capabilities ? <<-CAP : ""
          <Component Id="CapabilitiesComponent" Guid="*">
            <File Id="CapabilitiesFile" Name="capabilities.json" Source="#{safe_capabilities_source}" KeyPath="yes" />
          </Component>
CAP

            wxs = <<-WXS
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Id="*" Name="#{safe_name}" Version="#{safe_version}" Manufacturer="#{safe_publisher}" UpgradeCode="#{upgrade_code}">
    <Package InstallerVersion="200" Compressed="yes" InstallScope="perMachine" />
    <MajorUpgrade DowngradeErrorMessage="A newer version of [ProductName] is already installed." />
    <MediaTemplate />
    <Feature Id="ProductFeature" Title="#{safe_name}" Level="1">
      <ComponentRef Id="AppExeComponent" />
      <ComponentRef Id="ApplicationShortcut" />
#{resource_refs}#{capabilities_ref}    </Feature>
    <Directory Id="TARGETDIR" Name="SourceDir">
      <Directory Id="ProgramFiles64Folder">
        <Directory Id="INSTALLFOLDER" Name="#{safe_name}">
          <Component Id="AppExeComponent" Guid="*">
            <File Id="AppExe" Name="#{safe_name}.exe" Source="#{safe_exe_source}" KeyPath="yes" />
          </Component>
#{capabilities_component}#{resource_directory}        </Directory>
      </Directory>
      <Directory Id="ProgramMenuFolder">
        <Directory Id="ApplicationProgramsFolder" Name="#{safe_name}">
          <Component Id="ApplicationShortcut" Guid="*">
            <Shortcut Id="ApplicationStartMenuShortcut" Name="#{safe_name}" Description="#{safe_name}" Target="[INSTALLFOLDER]#{safe_name}.exe" WorkingDirectory="INSTALLFOLDER" />
            <RemoveFolder Id="RemoveApplicationProgramsFolder" On="uninstall" />
            <RegistryValue Root="HKCU" Key="Software\\#{safe_publisher}\\#{safe_name}" Name="installed" Type="integer" Value="1" KeyPath="yes" />
          </Component>
        </Directory>
      </Directory>
    </Directory>
  </Product>
</Wix>
WXS

            path = work_dir / "app.wxs"
            File.write(path.to_s, wxs)
            path.to_s
          end

          # :nodoc:
          private def build_resource_directory(work_dir : Path) : {String, String}
            resources_root = work_dir / "resources"
            return {"", ""} unless Dir.exists?(resources_root.to_s) && Common.any_files?(resources_root)
            component_refs = [] of String
            resource_directory = String.build do |io|
              write_resource_directory(io, resources_root, "ResourcesDir", "resources", component_refs)
            end
            {resource_directory, component_refs.join("\n")}
          end

          # :nodoc:
          private def write_resource_directory(io : IO, dir : Path, id : String, name : String, component_refs : Array(String)) : Nil
            io << "          <Directory Id=\"#{id}\" Name=\"#{Common.xml_escape(name)}\">\n"

            Dir.children(dir.to_s).sort.each do |entry|
              path = dir / entry
              if Dir.exists?(path.to_s)
                child_id = Common.identifier("#{id}_#{entry}")
                write_resource_directory(io, path, child_id, entry, component_refs)
              elsif File.file?(path.to_s)
                index = component_refs.size + 1
                component_id = "ResourceComponent#{index}"
                file_id = "ResourceFile#{index}"
                component_refs << "      <ComponentRef Id=\"#{component_id}\" />"
                io << "            <Component Id=\"#{component_id}\" Guid=\"*\">\n"
                io << "              <File Id=\"#{file_id}\" Name=\"#{Common.xml_escape(entry)}\" Source=\"#{Common.xml_escape(path.to_s)}\" KeyPath=\"yes\" />\n"
                io << "            </Component>\n"
              end
            end

            io << "          </Directory>\n"
          end

          # :nodoc:
          private def stage_resources(work_dir : Path) : Nil
            Common.stage_resource_tree(@resources_dir, @sidecar_dir, work_dir / "resources")
          end
        end

        # Signs a Windows file (installer or binary) with `signtool`.
        class Sign
          # :nodoc:
          Log = ::Log.for(self)

          # Path to the PFX/certificate file passed to `signtool /f`.
          getter certificate_path : String
          # Plaintext password forwarded to `signtool /p`, or `nil` to
          # omit the flag.
          getter password : String?

          # Creates a signer for *certificate_path*. *password* is the
          # resolved certificate password (typically read from the
          # environment by the caller).
          def initialize(@certificate_path : String, @password = nil)
          end

          # Signs *file_path* with SHA-256 using `signtool`, returning
          # `true` on success.
          def sign(file_path : String) : Bool
            args = ["sign", "/fd", "SHA256", "/a", "/f", certificate_path]
            if pwd = password
              # NOTE: Password passed via argv is visible via `ps`. For
              # production, use a PFX file with machine-key encryption.
              args.concat(["/p", pwd])
            end
            args << file_path

            out_io = IO::Memory.new
            err_io = IO::Memory.new
            result = Process.run("signtool", args,
              output: out_io, error: err_io)

            if result.success?
              Log.info { "Signed #{file_path}" }
              true
            else
              Log.error { "Signing failed: #{err_io}" }
              false
            end
          end
        end
      end
    end
  end
end
