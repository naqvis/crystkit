require "json"
require "http/client"
require "digest/sha256"
require "openssl"
require "log"
require "file_utils"
require "../platform/host"
require "../core/errors"

module CrystKit
  module Features
    # Update channels supported by the auto-updater.
    enum UpdateChannel
      Stable
      Beta
      Dev
    end

    # Lifecycle phase of an update operation.
    enum UpdatePhase
      Pending
      Downloading
      Downloaded
      Installing
      Installed
      RollingBack
      RolledBack
      Failed
    end

    # A single backup entry stored in the backup manifest.
    struct BackupEntry
      include JSON::Serializable

      # The application version string this backup corresponds to (e.g. `"1.2.3"`).
      getter version : String
      # The absolute path of the binary that was replaced; the rollback target.
      getter binary_path : String
      # The absolute path where the superseded binary was copied.
      getter backup_path : String
      # Millisecond-precision UTC timestamp at which the backup was recorded.
      getter timestamp : Int64

      # Creates a backup entry. *timestamp* is set to the current UTC
      # time in milliseconds.
      def initialize(@version : String, @binary_path : String, @backup_path : String)
        @timestamp = Time.utc.to_unix_ms
      end
    end

    # Semantic version representation for version comparison.
    #
    # Supports standard SemVer format: MAJOR.MINOR.PATCH with optional
    # pre-release labels (e.g., "1.2.3-beta.1").
    struct SemanticVersion
      include Comparable(SemanticVersion)

      # Major version component.
      getter major : Int32
      # Minor version component.
      getter minor : Int32
      # Patch version component.
      getter patch : Int32
      # Optional pre-release label (e.g. `"beta.1"`), or `nil` for a clean release.
      #
      # When present, `#<=>` orders this version *below* an otherwise-equal
      # release version per the SemVer specification.
      getter pre_release : String?

      # Creates a semantic version. Prefer `.parse` when building from a
      # version string.
      def initialize(@major : Int32, @minor : Int32, @patch : Int32, @pre_release = nil)
      end

      # Parses a version string like "1.2.3" or "1.2.3-beta.1".
      #
      # Accepts an optional leading `"v"` (stripped automatically).
      #
      # Raises `Core::ValidationError` if the string is not a valid semantic version.
      def self.parse(version : String) : SemanticVersion
        # Strip leading "v" if present
        v = version.lstrip("v")

        # Split on "-" to separate core version from pre-release.
        # Use a regex so that a leading "-" on a numeric component (e.g. "1.-1.0")
        # is NOT mistaken for the pre-release separator.
        if match = v.match(/\A(\d+\.\d+\.\d+)(?:-(.+))?\z/)
          core = match[1]
          pre = match[2]?
        else
          # Fall through to the segment-count check which will raise the right error,
          # unless the failure is due to negative components.
          core = v.split("-", 2)[0]
          pre = v.split("-", 2)[1]?
        end

        # Before splitting on ".", check if any dot-segment is a negative integer
        # (e.g. "1.-1.0"). We inspect the raw stripped string for this pattern.
        raw_dot_segments = v.split(".", 4)
        if raw_dot_segments.size >= 3 && raw_dot_segments[0..2].any? { |segment| segment =~ /\A-\d+\z/ }
          raise Core::ValidationError.new(
            "Invalid semantic version '#{version}': version components must be non-negative",
            field: "version"
          )
        end

        segments = core.split(".")
        unless segments.size == 3
          raise Core::ValidationError.new(
            "Invalid semantic version '#{version}': expected MAJOR.MINOR.PATCH",
            field: "version"
          )
        end

        major = segments[0].to_i?
        minor = segments[1].to_i?
        patch = segments[2].to_i?

        if major.nil? || minor.nil? || patch.nil?
          raise Core::ValidationError.new(
            "Invalid semantic version '#{version}': version components must be integers",
            field: "version"
          )
        end

        if major < 0 || minor < 0 || patch < 0
          raise Core::ValidationError.new(
            "Invalid semantic version '#{version}': version components must be non-negative",
            field: "version"
          )
        end

        new(major, minor, patch, pre)
      end

      # Compare two semantic versions.
      #
      # Pre-release versions are considered lower than the release version
      # (e.g., "1.0.0-beta" < "1.0.0").
      def <=>(other : SemanticVersion) : Int32
        return major <=> other.major unless major == other.major
        return minor <=> other.minor unless minor == other.minor
        return patch <=> other.patch unless patch == other.patch

        # Handle pre-release comparison:
        # A version without pre-release is greater than one with pre-release.
        case {pre_release, other.pre_release}
        when {nil, nil}    then 0
        when {nil, String} then 1  # release > pre-release
        when {String, nil} then -1 # pre-release < release
        else
          pre_release.as(String) <=> other.pre_release.as(String)
        end
      end

      # Returns the canonical string form (`"MAJOR.MINOR.PATCH"` with an
      # optional `-pre_release` suffix).
      def to_s : String
        base = "#{major}.#{minor}.#{patch}"
        pre_release ? "#{base}-#{pre_release}" : base
      end

      # Appends the canonical string form to *io*.
      def to_s(io : IO) : Nil
        io << to_s
      end
    end

    # Information about an available update.
    #
    # Describes one downloadable update package returned by the update
    # server's manifest.
    struct UpdateInfo
      include JSON::Serializable

      # The version string of the available update (e.g. `"1.3.0"`).
      getter version : String
      # Human-readable release notes to display to the user.
      getter release_notes : String
      # Absolute URL of the update package to download.
      getter download_url : String
      # Expected SHA-256 hex digest of the downloaded package, used to
      # verify integrity.
      getter signature : String
      # Declared package size in bytes, used to drive download progress.
      getter size : Int64
      # Channel the update belongs to (`"stable"`, `"beta"`, or `"dev"`).
      getter channel : String

      # Creates an update descriptor. Normally obtained via
      # `AutoUpdater#check_for_updates`.
      def initialize(
        @version : String,
        @release_notes : String,
        @download_url : String,
        @signature : String,
        @size : Int64,
        @channel : String,
      )
      end

      # Returns the parsed semantic version for this update.
      #
      # Raises `Core::ValidationError` if the version string is malformed.
      def semantic_version : SemanticVersion
        SemanticVersion.parse(@version)
      end
    end

    # Auto-updater for checking and managing application updates.
    #
    # Supports checking for updates from a remote server, comparing versions,
    # downloading update packages, verifying signatures, and update channels
    # (stable, beta, dev).
    class AutoUpdater
      # Default timeout for HTTP requests to the update server.
      DEFAULT_TIMEOUT = 30.seconds

      # Default download chunk size (64 KB).
      DOWNLOAD_CHUNK_SIZE = 65_536

      @current_version : SemanticVersion
      @update_url : String
      @channel : UpdateChannel
      @timeout : Time::Span
      @backup_dir : Path
      @phase : UpdatePhase

      # Handlers for update lifecycle events
      @update_available_handlers : Array(Proc(UpdateInfo, Nil))
      @download_progress_handlers : Array(Proc(Int32, Nil))
      @download_complete_handlers : Array(Proc(Path, Nil))
      @error_handlers : Array(Proc(Exception, Nil))
      @before_install_handlers : Array(Proc(Nil))
      @after_install_handlers : Array(Proc(Nil))

      # Creates a new AutoUpdater.
      #
      # Raises `Core::ValidationError` if *current_version* is not a valid semantic version.
      def initialize(
        current_version : String,
        @update_url : String,
        @channel = UpdateChannel::Stable,
        @timeout = DEFAULT_TIMEOUT,
        backup_dir : Path? = nil,
      )
        @current_version = SemanticVersion.parse(current_version)
        @backup_dir = backup_dir || default_backup_dir
        @phase = UpdatePhase::Pending
        @update_available_handlers = Array(Proc(UpdateInfo, Nil)).new
        @download_progress_handlers = Array(Proc(Int32, Nil)).new
        @download_complete_handlers = Array(Proc(Path, Nil)).new
        @error_handlers = Array(Proc(Exception, Nil)).new
        @before_install_handlers = Array(Proc(Nil)).new
        @after_install_handlers = Array(Proc(Nil)).new
      end

      # Returns the current application version.
      def current_version : SemanticVersion
        @current_version
      end

      # Returns the configured update channel.
      def channel : UpdateChannel
        @channel
      end

      # Returns the update server URL.
      def update_url : String
        @update_url
      end

      # Register a handler called when an update is available.
      def on_update_available(&handler : UpdateInfo ->) : Nil
        @update_available_handlers << handler
      end

      # Register a handler called with download progress percentage (0-100).
      def on_download_progress(&handler : Int32 ->) : Nil
        @download_progress_handlers << handler
      end

      # Register a handler called when a download completes successfully.
      # The handler receives the path to the downloaded package file.
      def on_download_complete(&handler : Path ->) : Nil
        @download_complete_handlers << handler
      end

      # Register a handler called when an error occurs during update checking or downloading.
      def on_error(&handler : Exception ->) : Nil
        @error_handlers << handler
      end

      # Checks for updates from the remote server.
      #
      # Returns `nil` if the application is already up to date.
      # Raises `Core::NetworkError` if the server cannot be reached.
      # Raises `Core::ValidationError` if the manifest is malformed.
      def check_for_updates : UpdateInfo?
        manifest_url = build_manifest_url
        Log.debug { "AutoUpdater: checking for updates at #{manifest_url} (channel: #{@channel})" }

        response = fetch_manifest(manifest_url)
        info = parse_manifest(response)

        return nil if info.nil?

        available = SemanticVersion.parse(info.version)

        if available > @current_version
          Log.info { "AutoUpdater: update available #{@current_version} -> #{available}" }
          emit_update_available(info)
          info
        else
          Log.debug { "AutoUpdater: already up to date (#{@current_version})" }
          nil
        end
      rescue ex : Core::NetworkError | Core::ValidationError
        emit_error(ex)
        raise ex
      rescue ex
        wrapped = Core::NetworkError.new(
          "Update check failed: #{ex.message}",
          code: "UPDATE_CHECK_FAILED"
        )
        emit_error(wrapped)
        raise wrapped
      end

      # Returns `true` when *version* is newer than the current version.
      #
      # Useful for manual version comparisons without hitting the network.
      def newer_version?(version : String) : Bool
        SemanticVersion.parse(version) > @current_version
      end

      # Compares two version strings, returning -1, 0, or 1.
      def self.compare_versions(a : String, b : String) : Int32
        SemanticVersion.parse(a) <=> SemanticVersion.parse(b)
      end

      # Downloads an update package described by *info* to a temporary file.
      # Progress is reported via `on_download_progress` handlers.
      # Raises `Core::ValidationError` on signature mismatch.
      # Returns the path to the downloaded file.
      def download_update(info : UpdateInfo) : Path
        if !info.download_url || info.download_url.empty?
          raise Core::ValidationError.new(
            "Update info has no download URL",
            field: "download_url"
          )
        end

        @phase = UpdatePhase::Downloading
        dest = Path.new(File.tempname("webview_update", ".pkg"))
        Log.info { "AutoUpdater: downloading update #{info.version} from #{info.download_url}" }

        begin
          stream_download(info.download_url, dest, info.size)
          verify_signature!(dest, info.signature)
        rescue ex
          @phase = UpdatePhase::Failed
          File.delete(dest.to_s) if File.exists?(dest.to_s)
          emit_error(ex)
          raise ex
        end

        @phase = UpdatePhase::Downloaded
        Log.info { "AutoUpdater: download complete, package at #{dest}" }
        emit_download_complete(dest)
        dest
      rescue ex : Core::ValidationError | Core::NetworkError
        raise ex
      rescue ex
        @phase = UpdatePhase::Failed
        wrapped = Core::NetworkError.new(
          "Update download failed: #{ex.message}",
          code: "UPDATE_DOWNLOAD_FAILED"
        )
        emit_error(wrapped)
        raise wrapped
      end

      # Verifies that the SHA-256 hex digest of *file* matches *expected_signature*.
      #
      # Raises `Core::ValidationError` if the signature does not match or
      # *expected_signature* is blank.
      def verify_package_signature(file : Path, expected_signature : String) : Bool
        verify_signature!(file, expected_signature)
        true
      end

      # Builds the manifest URL for the current channel.
      # :nodoc:
      private def build_manifest_url : String
        channel_name = @channel.to_s.downcase
        base = @update_url.rstrip("/")
        "#{base}/#{channel_name}/latest.json"
      end

      # Fetch the update manifest from the remote server.
      # :nodoc:
      private def fetch_manifest(url : String) : String
        uri = URI.parse(url)
        client = HTTP::Client.new(uri)
        client.connect_timeout = @timeout
        client.read_timeout = @timeout

        response = client.get(uri.request_target)

        unless response.status.success?
          raise Core::NetworkError.new(
            "Update server returned HTTP #{response.status_code} for #{url}",
            code: "UPDATE_SERVER_ERROR"
          )
        end

        response.body
      rescue ex : IO::TimeoutError
        raise Core::NetworkError.new(
          "Update check timed out connecting to #{url}",
          code: "UPDATE_TIMEOUT"
        )
      rescue ex : Socket::Error
        raise Core::NetworkError.new(
          "Cannot connect to update server: #{ex.message}",
          code: "UPDATE_CONNECTION_ERROR"
        )
      rescue ex : Core::NetworkError
        raise ex
      rescue ex
        raise Core::NetworkError.new(
          "Failed to fetch update manifest: #{ex.message}",
          code: "UPDATE_FETCH_FAILED"
        )
      end

      # Parses the update manifest JSON into an `UpdateInfo` struct.
      #
      # Returns `nil` if the manifest indicates no update is available.
      # :nodoc:
      private def parse_manifest(body : String) : UpdateInfo?
        json = JSON.parse(body)

        # A manifest may explicitly signal "no update" with a null or empty version
        version = json["version"]?.try(&.as_s?)
        return nil if version.nil? || version.empty?

        release_notes = json["release_notes"]?.try(&.as_s?) || ""
        download_url = json["download_url"]?.try(&.as_s?) || ""
        signature = json["signature"]?.try(&.as_s?) || ""
        size = json["size"]?.try(&.as_i64?) || 0_i64
        channel = json["channel"]?.try(&.as_s?) || @channel.to_s.downcase

        UpdateInfo.new(
          version: version,
          release_notes: release_notes,
          download_url: download_url,
          signature: signature,
          size: size,
          channel: channel
        )
      rescue ex : JSON::ParseException
        raise Core::ValidationError.new(
          "Invalid update manifest JSON: #{ex.message}",
          field: "manifest"
        )
      end

      # Emit the update-available event to all registered handlers.
      # :nodoc:
      private def emit_update_available(info : UpdateInfo) : Nil
        @update_available_handlers.each do |handler|
          begin
            handler.call(info)
          rescue ex
            Log.error { "AutoUpdater: on_update_available handler raised: #{ex.message}" }
          end
        end
      end

      # Emit an error event to all registered error handlers.
      # :nodoc:
      private def emit_error(ex : Exception) : Nil
        @error_handlers.each do |handler|
          begin
            handler.call(ex)
          rescue error
            Log.error { "AutoUpdater: on_error handler raised: #{error.message}" }
          end
        end
      end

      # Emit a download-complete event to all registered handlers.
      # :nodoc:
      private def emit_download_complete(path : Path) : Nil
        @download_complete_handlers.each do |handler|
          begin
            handler.call(path)
          rescue ex
            Log.error { "AutoUpdater: on_download_complete handler raised: #{ex.message}" }
          end
        end
      end

      # Emit a download-progress event (percentage 0-100) to all registered handlers.
      # :nodoc:
      private def emit_download_progress(percent : Int32) : Nil
        @download_progress_handlers.each do |handler|
          begin
            handler.call(percent)
          rescue ex
            Log.error { "AutoUpdater: on_download_progress handler raised: #{ex.message}" }
          end
        end
      end

      # ── Install & Rollback ─────────────────────────────────────────────────────

      # Register a handler called before the update is installed.
      def on_before_install(&handler : ->) : Nil
        @before_install_handlers << handler
      end

      # Register a handler called after the update is installed.
      def on_after_install(&handler : ->) : Nil
        @after_install_handlers << handler
      end

      # Returns the current update phase.
      def phase : UpdatePhase
        @phase
      end

      # Reset the phase to Pending. Useful for recovery after a failed
      # or cancelled operation.
      def reset_phase : Nil
        @phase = UpdatePhase::Pending
      end

      # Returns the backup directory used for storing previous versions.
      def backup_dir : Path
        @backup_dir
      end

      # Installs a downloaded update package.
      #
      # Returns the path to a swap script that the caller should execute
      # (e.g. via `Process.run`) before terminating the application, so
      # the script can replace the binary and launch the new version.
      #
      # Raises `Core::Error` (codes `UPDATE_IN_PROGRESS`,
      # `PACKAGE_NOT_FOUND`, `APP_PATH_UNKNOWN`) on failure.
      def install_update(info : UpdateInfo, package_path : Path, app_path : Path? = nil) : Path
        if @phase.installing? || @phase.rolling_back?
          raise Core::Error.new(
            "Cannot install while phase is #{@phase}",
            code: "UPDATE_IN_PROGRESS"
          )
        end

        unless File.exists?(package_path.to_s)
          raise Core::Error.new(
            "Package not found: #{package_path}",
            code: "PACKAGE_NOT_FOUND"
          )
        end

        target = app_path || current_app_path
        if target.nil? || !File.exists?(target.to_s)
          raise Core::Error.new(
            "Cannot determine current application binary path",
            code: "APP_PATH_UNKNOWN"
          )
        end

        @phase = UpdatePhase::Installing

        begin
          backup = create_backup(info, target)
          record_backup(backup)

          swap_script = write_swap_script(target, package_path, backup)

          emit_before_install

          Log.info { "AutoUpdater: install prepared, swap script at #{swap_script}" }
          swap_script
        rescue ex
          @phase = UpdatePhase::Failed
          emit_error(ex)
          raise ex
        end
      end

      # Rolls back to a previous version.
      #
      # If *version* is provided, restores that specific backup; otherwise
      # restores the most recent backup. Returns the path to the swap
      # script for the caller to execute.
      #
      # Raises `Core::Error` (codes `UPDATE_IN_PROGRESS`,
      # `NO_BACKUP`, `APP_PATH_UNKNOWN`, `BACKUP_NOT_FOUND`) on failure.
      def rollback(version : String? = nil) : Path
        if @phase.installing? || @phase.rolling_back?
          raise Core::Error.new(
            "Cannot rollback while phase is #{@phase}",
            code: "UPDATE_IN_PROGRESS"
          )
        end

        @phase = UpdatePhase::RollingBack

        begin
          backup = find_backup(version)
          if backup.nil?
            raise Core::Error.new(
              "No backup found#{version ? " for version #{version}" : ""}",
              code: "NO_BACKUP"
            )
          end

          target = Path.new(backup.binary_path)
          unless File.exists?(target.to_s)
            raise Core::Error.new(
              "Target binary not found: #{target}",
              code: "APP_PATH_UNKNOWN"
            )
          end

          backup_path = Path.new(backup.backup_path)
          unless File.exists?(backup_path.to_s)
            raise Core::Error.new(
              "Backup binary not found: #{backup_path}",
              code: "BACKUP_NOT_FOUND"
            )
          end

          swap_script = write_rollback_script(target, backup_path)
          Log.info { "AutoUpdater: rollback prepared, swap script at #{swap_script}" }
          swap_script
        rescue ex
          @phase = UpdatePhase::Failed
          emit_error(ex)
          raise ex
        end
      end

      # Applies a binary delta patch to produce a new binary.
      def apply_delta(base_path : Path, delta_path : Path, output_path : Path) : Nil
        base = File.read(base_path.to_s).to_slice
        delta = File.read(delta_path.to_s).to_slice
        output_size = delta.size >= 8 ? IO::ByteFormat::LittleEndian.decode(Int64, delta[0, 8]).to_i : 0
        delta_start = 8

        output = Bytes.new(output_size > 0 ? output_size : base.size)
        output.copy_from(base)

        i = delta_start
        while i < delta.size
          offset = IO::ByteFormat::LittleEndian.decode(Int64, delta[i, 8]).to_i
          byte = delta[i + 8]
          output[offset] ^= byte if offset < output.size
          i += 9
        end

        File.write(output_path.to_s, output)
        File.chmod(output_path.to_s, File.info(base_path.to_s).permissions)
      rescue ex
        raise Core::Error.new(
          "Delta application failed: #{ex.message}",
          code: "DELTA_FAILED"
        )
      end

      # ── Private helpers ────────────────────────────────────────────────────────

      # Returns the path to the current running executable.
      # :nodoc:
      private def current_app_path : Path?
        if path = Process.executable_path
          Path.new(path)
        end
      end

      # Backup directory derived from the update URL hostname.
      # :nodoc:
      private def default_backup_dir : Path
        host = URI.parse(@update_url).host || "unknown"
        Path.new(Dir.tempdir) / "webview_updater" / host
      end

      # Create a backup of the current binary.
      # :nodoc:
      private def create_backup(info : UpdateInfo, target : Path) : BackupEntry
        dir = @backup_dir / info.version
        FileUtils.mkdir_p(dir.to_s)

        backup_path = dir / target.basename
        if File.exists?(backup_path.to_s)
          File.delete(backup_path.to_s)
        end
        FileUtils.cp(target.to_s, backup_path.to_s)

        BackupEntry.new(info.version, target.to_s, backup_path.to_s)
      end

      # Write a platform-specific swap script that replaces the binary.
      # :nodoc:
      private def write_swap_script(target : Path, package : Path, backup : BackupEntry) : Path
        script_dir = @backup_dir / "scripts"
        FileUtils.mkdir_p(script_dir.to_s)
        script_path = script_dir / "install_#{backup.version}"

        Platform::Host.write_replacement_script(script_path, package, target)
      end

      # Write a rollback swap script.
      # :nodoc:
      private def write_rollback_script(target : Path, backup_path : Path) : Path
        script_dir = @backup_dir / "scripts"
        FileUtils.mkdir_p(script_dir.to_s)
        script_path = script_dir / "rollback"

        Platform::Host.write_replacement_script(script_path, backup_path, target)
      end

      # Manifest file path.
      # :nodoc:
      private def manifest_path : Path
        @backup_dir / "backup_manifest.json"
      end

      # Record a backup entry in the manifest.
      # :nodoc:
      private def record_backup(entry : BackupEntry) : Nil
        entries = load_manifest
        # Remove any existing entry for the same version
        entries.reject! { |e| e.version == entry.version }
        entries << entry
        # Keep only the last 5 backups
        entries = entries.last(5)
        File.write(manifest_path.to_s, entries.to_json)
      end

      # Load the backup manifest.
      # :nodoc:
      private def load_manifest : Array(BackupEntry)
        path = manifest_path
        return [] of BackupEntry unless File.exists?(path.to_s)
        Array(BackupEntry).from_json(File.read(path.to_s))
      rescue
        [] of BackupEntry
      end

      # Find a backup entry by version, or the most recent.
      # :nodoc:
      private def find_backup(version : String? = nil) : BackupEntry?
        entries = load_manifest
        return nil if entries.empty?
        if v = version
          entries.find { |e| e.version == v }
        else
          entries.max_by?(&.timestamp)
        end
      end

      # Emit before-install event to all registered handlers.
      # :nodoc:
      private def emit_before_install : Nil
        @before_install_handlers.each do |handler|
          begin
            handler.call
          rescue ex
            Log.error { "AutoUpdater: on_before_install handler raised: #{ex.message}" }
          end
        end
      end

      # Emit after-install event to all registered handlers.
      # :nodoc:
      private def emit_after_install : Nil
        @after_install_handlers.each do |handler|
          begin
            handler.call
          rescue ex
            Log.error { "AutoUpdater: on_after_install handler raised: #{ex.message}" }
          end
        end
      end

      # Streams a file download from *url* to *dest*, reporting progress.
      #
      # When *total_size* > 0, progress is reported as a percentage
      # (0-100) via `emit_download_progress`. Otherwise progress is
      # reported only at 0% and 100%.
      #
      # Raises `Core::NetworkError` on connection or I/O failures.
      # :nodoc:
      private def stream_download(url : String, dest : Path, total_size : Int64) : Nil
        uri = URI.parse(url)
        client = HTTP::Client.new(uri)
        client.connect_timeout = @timeout
        client.read_timeout = @timeout

        emit_download_progress(0)

        bytes_received = 0_i64

        client.get(uri.request_target) do |response|
          unless response.status.success?
            raise Core::NetworkError.new(
              "Download server returned HTTP #{response.status_code} for #{url}",
              code: "DOWNLOAD_SERVER_ERROR"
            )
          end

          # Use Content-Length from response if total_size was not provided.
          effective_total = total_size > 0 ? total_size : (response.headers["Content-Length"]?.try(&.to_i64?) || 0_i64)

          File.open(dest.to_s, "wb") do |file|
            buf = Bytes.new(DOWNLOAD_CHUNK_SIZE)
            loop do
              bytes_read = response.body_io.read(buf)
              break if bytes_read == 0

              file.write(buf[0, bytes_read])
              bytes_received += bytes_read

              if effective_total > 0
                percent = ((bytes_received.to_f64 / effective_total.to_f64) * 100.0).clamp(0.0, 100.0).to_i
                emit_download_progress(percent)
              end
            end
          end
        end

        emit_download_progress(100)
      rescue ex : IO::TimeoutError
        raise Core::NetworkError.new(
          "Download timed out for #{url}",
          code: "DOWNLOAD_TIMEOUT"
        )
      rescue ex : Socket::Error
        raise Core::NetworkError.new(
          "Cannot connect to download server: #{ex.message}",
          code: "DOWNLOAD_CONNECTION_ERROR"
        )
      rescue ex : Core::NetworkError
        raise ex
      rescue ex
        raise Core::NetworkError.new(
          "Download failed: #{ex.message}",
          code: "DOWNLOAD_FAILED"
        )
      end

      # Verifies the SHA-256 hex digest of *file* against *expected_signature*.
      #
      # Raises `Core::ValidationError` if *expected_signature* is blank
      # or the computed digest does not match.
      # :nodoc:
      private def verify_signature!(file : Path, expected_signature : String) : Nil
        if expected_signature.empty?
          raise Core::ValidationError.new(
            "Cannot verify package: expected signature is blank",
            field: "signature"
          )
        end

        digest = Digest::SHA256.new
        File.open(file.to_s, "rb") do |file_io|
          buf = Bytes.new(DOWNLOAD_CHUNK_SIZE)
          loop do
            bytes_read = file_io.read(buf)
            break if bytes_read == 0
            digest.update(buf[0, bytes_read])
          end
        end

        actual = digest.final.hexstring

        unless actual == expected_signature.downcase
          raise Core::ValidationError.new(
            "Package signature mismatch: expected #{expected_signature}, got #{actual}",
            field: "signature"
          )
        end
      end
    end
  end
end
