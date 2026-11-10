require "log"
require "file_utils"
require "../common"

module CrystKit::Builder::Bundle::Windows
  # Builds a Windows NSIS installer from a compiled binary.
  class Nsis
    # :nodoc:
    Log = ::Log.for(self)

    # The project configuration supplying package metadata and bundle settings.
    getter config : Config
    # Path to the compiled binary to package.
    getter binary_path : String
    # Directory where the installer and staging dirs are written.
    getter output_dir : String
    # Staged sidecar directory, or `nil` when no sidecars were prepared.
    getter sidecar_dir : String?
    # Staged frontend resources directory, or `nil` when none were prepared.
    getter resources_dir : String?

    # Creates an NSIS installer generator.
    def initialize(@config : Config, @binary_path : String, @output_dir : String, @sidecar_dir = nil, @resources_dir = nil)
    end

    # Builds the NSIS installer and returns its path.
    #
    # Raises with a hint to install NSIS if `makensis` is not found.
    def generate : String
      app_name = config.package.name
      version = config.package.version

      work_dir = Path[output_dir] / "nsis_work"
      Dir.mkdir_p(work_dir.to_s)

      dest_binary = work_dir / "#{app_name}.exe"
      File.copy(binary_path, dest_binary.to_s)
      stage_resources(work_dir)

      script_path = write_script(work_dir, app_name, version)

      installer_path = Path[output_dir] / "#{app_name}-Setup-#{version}.exe"
      err_io = IO::Memory.new
      result = Process.run("makensis", [
        "/V2",
        "/DInstallDir=#{app_name}",
        "/DName=#{app_name}",
        "/DVersion=#{version}",
        "/DPublisher=#{config.package.publisher}",
        "/DOutFile=#{installer_path}",
        script_path,
      ], output: Process::Redirect::Close, error: err_io)

      FileUtils.rm_rf(work_dir.to_s)

      unless result.success?
        msg = err_io.to_s
        if msg.includes?("not found") || msg.includes?("not recognized")
          raise "NSIS (makensis) not found. Install NSIS from https://nsis.sourceforge.io"
        end
        raise "NSIS build failed: #{msg}"
      end

      Log.info { "Created NSIS installer at #{installer_path}" }
      installer_path.to_s
    end

    # :nodoc:
    private def write_script(work_dir : Path, app_name : String, version : String) : String
      icon = find_icon
      resources = work_dir / "resources"
      install_resources = Dir.exists?(resources.to_s) && Common.any_files?(resources) ? <<-NSIS : ""
  File /r "#{resources}"
NSIS
      uninstall_resources = Dir.exists?(resources.to_s) && Common.any_files?(resources) ? <<-NSIS : ""
  RMDir /r "$INSTDIR\\resources"
NSIS
      capabilities_path = (work_dir / "capabilities.json").to_s
      has_capabilities = File.exists?(capabilities_path)
      script = <<-NSIS
!include "MUI2.nsh"

Name "${Name}"
OutFile "${OutFile}"
InstallDir "$PROGRAMFILES64\\${InstallDir}"
RequestExecutionLevel admin

!define MUI_ABORTWARNING
!define MUI_ICON "#{icon}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_LANGUAGE "English"

Section "Install"
  SetOutPath "$INSTDIR"
  File "#{work_dir / "#{app_name}.exe"}"
#{has_capabilities ? "  File \"#{capabilities_path}\"\n" : ""}#{install_resources}
  CreateShortCut "$SMPROGRAMS\\${Name}.lnk" "$INSTDIR\\#{app_name}.exe"

  WriteUninstaller "$INSTDIR\\Uninstall.exe"

  WriteRegStr HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${Name}" \
    "DisplayName" "${Name}"
  WriteRegStr HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${Name}" \
    "DisplayVersion" "${Version}"
  WriteRegStr HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${Name}" \
    "Publisher" "${Publisher}"
  WriteRegStr HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${Name}" \
    "UninstallString" '"$INSTDIR\\Uninstall.exe"'
  WriteRegDWORD HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${Name}" \
    "NoModify" 1
  WriteRegDWORD HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${Name}" \
    "NoRepair" 1
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\\#{app_name}.exe"
  Delete "$INSTDIR\\Uninstall.exe"
#{has_capabilities ? "  Delete \"$INSTDIR\\capabilities.json\"\n" : ""}#{uninstall_resources}
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\\${Name}.lnk"

  DeleteRegKey HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${Name}"
SectionEnd
NSIS
      path = work_dir / "installer.nsi"
      File.write(path.to_s, script)
      path.to_s
    end

    # :nodoc:
    private def stage_resources(work_dir : Path) : Nil
      Common.stage_resource_tree(@resources_dir, @sidecar_dir, work_dir / "resources")
    end

    # :nodoc:
    private def find_icon : String
      icon_paths = config.bundle.icon.map { |i| config.resolve(i).to_s }
      Common.find_icon_by_ext(icon_paths, ".ico") || Common.first_existing_icon(icon_paths) || ""
    end
  end
end
