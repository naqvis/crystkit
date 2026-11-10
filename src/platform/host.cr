require "file_utils"

module CrystKit::Platform
  # Host-environment introspection helpers.
  #
  # Exposes static facts about the compilation target (OS, architecture,
  # executable extension) and runtime helpers that depend on them.
  module Host
    extend self

    # Returns `true` when CrystKit was compiled for Windows.
    def windows? : Bool
      {% if flag?(:windows) %}
        true
      {% else %}
        false
      {% end %}
    end

    # Returns the LLVM-style target triple for the current platform and
    # architecture.
    #
    # The triple follows the `arch-vendor-os-abi` convention used by LLVM
    # and Rust (for example `aarch64-apple-darwin` or
    # `x86_64-pc-windows-msvc`). Returns `"unknown"` when the running
    # target is not recognised.
    def target_triple : String
      {% if flag?(:darwin) && flag?(:aarch64) %}
        "aarch64-apple-darwin"
      {% elsif flag?(:darwin) && flag?(:x86_64) %}
        "x86_64-apple-darwin"
      {% elsif flag?(:linux) && flag?(:x86_64) %}
        "x86_64-unknown-linux-gnu"
      {% elsif flag?(:linux) && flag?(:aarch64) %}
        "aarch64-unknown-linux-gnu"
      {% elsif flag?(:win32) && flag?(:x86_64) %}
        "x86_64-pc-windows-msvc"
      {% elsif flag?(:win32) && flag?(:aarch64) %}
        "aarch64-pc-windows-msvc"
      {% else %}
        "unknown"
      {% end %}
    end

    # Returns the native executable suffix for the current platform.
    #
    # `".exe"` on Windows and an empty string elsewhere.
    def executable_extension : String
      windows? ? ".exe" : ""
    end

    # Returns `true` when the current target provides a native filesystem
    # event watcher.
    def native_file_watcher_available? : Bool
      {% if flag?(:darwin) || flag?(:linux) || flag?(:win32) %}
        true
      {% else %}
        false
      {% end %}
    end

    # Returns the `Resources` directory of a macOS `.app` bundle, or `nil`
    # when the running executable is not inside a bundle (or on non-macOS
    # targets).
    #
    # The directory is only returned when it exists on disk.
    def bundle_resource_dir : String?
      {% if flag?(:darwin) %}
        if (bundle = Process.executable_path) && bundle.includes?(".app/Contents/MacOS/")
          resources = File.join(File.dirname(File.dirname(bundle)), "Resources")
          return resources if Dir.exists?(resources)
        end
      {% end %}
      nil
    end

    # Writes a self-deleting helper script that replaces *target* with
    # *source* and relaunches it, returning the path of the written
    # script.
    #
    # The caller is responsible for spawning the returned script before
    # exiting the current process.
    def write_replacement_script(script_path : Path, source : Path, target : Path) : Path
      if windows?
        path = Path.new(script_path.to_s + ".bat")
        File.write(path.to_s, <<-BAT)
        @echo off
        timeout /t 2 /nobreak >nul
        copy /Y "#{source}" "#{target}" >nul
        start "" "#{target}"
        del "%~f0"
        BAT
        path
      else
        File.write(script_path.to_s, <<-SH)
        #!/bin/sh
        sleep 2
        cp "#{source}" "#{target}"
        chmod +x "#{target}"
        "#{target}" &
        rm -- "$0"
        SH
        File.chmod(script_path.to_s, 0o755)
        script_path
      end
    end
  end
end
