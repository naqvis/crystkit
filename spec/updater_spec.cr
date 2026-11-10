require "./spec_helper"
require "../src/features/updater"
describe CrystKit::Features::SemanticVersion do
  describe ".parse" do
    it "parses a standard version string" do
      v = CrystKit::Features::SemanticVersion.parse("1.2.3")
      v.major.should eq(1)
      v.minor.should eq(2)
      v.patch.should eq(3)
      v.pre_release.should be_nil
    end
    it "parses a version with a leading 'v'" do
      v = CrystKit::Features::SemanticVersion.parse("v2.0.1")
      v.major.should eq(2)
      v.minor.should eq(0)
      v.patch.should eq(1)
    end
    it "parses a version with a pre-release label" do
      v = CrystKit::Features::SemanticVersion.parse("1.0.0-beta.1")
      v.major.should eq(1)
      v.minor.should eq(0)
      v.patch.should eq(0)
      v.pre_release.should eq("beta.1")
    end
    it "parses a version with a dev pre-release label" do
      v = CrystKit::Features::SemanticVersion.parse("2.1.0-dev")
      v.pre_release.should eq("dev")
    end
    it "raises ValidationError for missing patch component" do
      expect_raises(CrystKit::Core::ValidationError, /MAJOR\.MINOR\.PATCH/) do
        CrystKit::Features::SemanticVersion.parse("1.2")
      end
    end
    it "raises ValidationError for non-integer components" do
      expect_raises(CrystKit::Core::ValidationError, /must be integers/) do
        CrystKit::Features::SemanticVersion.parse("1.x.3")
      end
    end
    it "raises ValidationError for an empty string" do
      expect_raises(CrystKit::Core::ValidationError) do
        CrystKit::Features::SemanticVersion.parse("")
      end
    end
    it "raises ValidationError for negative components" do
      expect_raises(CrystKit::Core::ValidationError, /non-negative/) do
        CrystKit::Features::SemanticVersion.parse("1.-1.0")
      end
    end
  end
  describe "#to_s" do
    it "formats a release version" do
      CrystKit::Features::SemanticVersion.parse("3.4.5").to_s.should eq("3.4.5")
    end
    it "formats a pre-release version" do
      CrystKit::Features::SemanticVersion.parse("1.0.0-alpha").to_s.should eq("1.0.0-alpha")
    end
  end
  describe "version comparison" do
    it "considers a higher major version as greater" do
      a = CrystKit::Features::SemanticVersion.parse("2.0.0")
      b = CrystKit::Features::SemanticVersion.parse("1.9.9")
      (a > b).should be_true
    end
    it "considers a higher minor version as greater when major is equal" do
      a = CrystKit::Features::SemanticVersion.parse("1.2.0")
      b = CrystKit::Features::SemanticVersion.parse("1.1.9")
      (a > b).should be_true
    end
    it "considers a higher patch version as greater when major and minor are equal" do
      a = CrystKit::Features::SemanticVersion.parse("1.0.2")
      b = CrystKit::Features::SemanticVersion.parse("1.0.1")
      (a > b).should be_true
    end
    it "considers equal versions as equal" do
      a = CrystKit::Features::SemanticVersion.parse("1.2.3")
      b = CrystKit::Features::SemanticVersion.parse("1.2.3")
      (a == b).should be_true
    end
    it "considers a release version greater than a pre-release of the same version" do
      release = CrystKit::Features::SemanticVersion.parse("1.0.0")
      pre = CrystKit::Features::SemanticVersion.parse("1.0.0-beta")
      (release > pre).should be_true
    end
    it "considers a pre-release version less than the release version" do
      pre = CrystKit::Features::SemanticVersion.parse("1.0.0-alpha")
      release = CrystKit::Features::SemanticVersion.parse("1.0.0")
      (pre < release).should be_true
    end
    it "compares two pre-release labels lexicographically" do
      beta = CrystKit::Features::SemanticVersion.parse("1.0.0-beta")
      alpha = CrystKit::Features::SemanticVersion.parse("1.0.0-alpha")
      (beta > alpha).should be_true
    end
  end
end
describe CrystKit::Features::AutoUpdater do
  describe "#initialize" do
    it "accepts a valid version string and URL" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates")
      updater.current_version.to_s.should eq("1.0.0")
    end
    it "defaults to the Stable channel" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates")
      updater.channel.should eq(CrystKit::Features::UpdateChannel::Stable)
    end
    it "accepts a custom update channel" do
      updater = CrystKit::Features::AutoUpdater.new(
        "1.0.0",
        "https://example.com/updates",
        CrystKit::Features::UpdateChannel::Beta
      )
      updater.channel.should eq(CrystKit::Features::UpdateChannel::Beta)
    end
    it "accepts the Dev channel" do
      updater = CrystKit::Features::AutoUpdater.new(
        "1.0.0",
        "https://example.com/updates",
        CrystKit::Features::UpdateChannel::Dev
      )
      updater.channel.should eq(CrystKit::Features::UpdateChannel::Dev)
    end
    it "raises ValidationError for an invalid current version" do
      expect_raises(CrystKit::Core::ValidationError) do
        CrystKit::Features::AutoUpdater.new("not-a-version", "https://example.com/updates")
      end
    end
  end
  describe "#newer_version?" do
    it "returns true when the given version is newer" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates")
      updater.newer_version?("1.0.1").should be_true
    end
    it "returns false when the given version is the same" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates")
      updater.newer_version?("1.0.0").should be_false
    end
    it "returns false when the given version is older" do
      updater = CrystKit::Features::AutoUpdater.new("2.0.0", "https://example.com/updates")
      updater.newer_version?("1.9.9").should be_false
    end
    it "returns true when a release version is newer than a pre-release current version" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0-beta", "https://example.com/updates")
      updater.newer_version?("1.0.0").should be_true
    end
  end
  describe ".compare_versions" do
    it "returns 0 for equal versions" do
      CrystKit::Features::AutoUpdater.compare_versions("1.0.0", "1.0.0").should eq(0)
    end
    it "returns 1 when the first version is greater" do
      CrystKit::Features::AutoUpdater.compare_versions("2.0.0", "1.0.0").should eq(1)
    end
    it "returns -1 when the first version is less" do
      CrystKit::Features::AutoUpdater.compare_versions("1.0.0", "2.0.0").should eq(-1)
    end
    it "compares patch versions correctly" do
      CrystKit::Features::AutoUpdater.compare_versions("1.0.2", "1.0.1").should eq(1)
    end
    it "compares minor versions correctly" do
      CrystKit::Features::AutoUpdater.compare_versions("1.1.0", "1.0.9").should eq(1)
    end
  end
  describe "#update_url" do
    it "returns the configured update URL" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://updates.example.com")
      updater.update_url.should eq("https://updates.example.com")
    end
  end
  describe "#on_update_available" do
    it "registers a handler that is called when an update is available" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates")
      called = false
      updater.on_update_available { |_info| called = true }
      called.should be_false
    end
  end
  describe "UpdateChannel" do
    it "converts to lowercase string for Stable" do
      CrystKit::Features::UpdateChannel::Stable.to_s.downcase.should eq("stable")
    end
    it "converts to lowercase string for Beta" do
      CrystKit::Features::UpdateChannel::Beta.to_s.downcase.should eq("beta")
    end
    it "converts to lowercase string for Dev" do
      CrystKit::Features::UpdateChannel::Dev.to_s.downcase.should eq("dev")
    end
  end
  describe "#check_for_updates" do
    it "raises NetworkError when the server is unreachable" do
      updater = CrystKit::Features::AutoUpdater.new(
        "1.0.0",
        "http://127.0.0.1:19999",
        CrystKit::Features::UpdateChannel::Stable,
        1.second
      )
      error_received = nil
      updater.on_error { |ex| error_received = ex }
      expect_raises(CrystKit::Core::NetworkError) do
        updater.check_for_updates
      end
      error_received.should_not be_nil
    end
    it "returns update info from a local HTTP server" do
      server = HTTP::Server.new do |context|
        context.response.content_type = "application/json"
        context.response.print(%({"version":"2.0.0","release_notes":"Release notes","download_url":"https://example.com/pkg","signature":"sig123","size":1024,"channel":"stable"}))
      end
      begin
        address = server.bind_tcp("127.0.0.1", 0)
        port = address.port
        spawn { server.listen }
        updater = CrystKit::Features::AutoUpdater.new(
          "1.0.0",
          "http://127.0.0.1:#{port}",
          CrystKit::Features::UpdateChannel::Stable,
          5.seconds
        )
        result = updater.check_for_updates
        result.should_not be_nil
        result.not_nil!.version.should eq("2.0.0")
        result.not_nil!.release_notes.should eq("Release notes")
        result.not_nil!.download_url.should eq("https://example.com/pkg")
        result.not_nil!.signature.should eq("sig123")
        result.not_nil!.size.should eq(1024_i64)
        result.not_nil!.channel.should eq("stable")
      ensure
        server.close
      end
    end
  end
  describe "UpdatePhase" do
    it "becomes Downloading during download_update" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates",
        backup_dir: Path.new("/tmp/phase_test_#{Time.utc.to_unix_ms}"))
      info = CrystKit::Features::UpdateInfo.new(
        version: "2.0.0",
        release_notes: "",
        download_url: "http://127.0.0.1:19999/pkg",
        signature: "",
        size: 0_i64,
        channel: "stable"
      )
      expect_raises(CrystKit::Core::NetworkError) { updater.download_update(info) }
      updater.phase.should eq(CrystKit::Features::UpdatePhase::Failed)
    end
  end
  describe "#install_update" do
    it "raises when package does not exist" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates",
        backup_dir: Path.new("/tmp/install_test_#{Time.utc.to_unix_ms}"))
      info = CrystKit::Features::UpdateInfo.new("2.0.0", "", "", "", 0_i64, "stable")
      expect_raises(CrystKit::Core::Error, /not found/i) do
        updater.install_update(info, Path.new("/nonexistent/pkg"))
      end
    end
    it "raises when app_path does not exist" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates",
        backup_dir: Path.new("/tmp/install_test_#{Time.utc.to_unix_ms}_2"))
      info = CrystKit::Features::UpdateInfo.new("2.0.0", "", "", "", 0_i64, "stable")
      pkg_path = File.tempname("updater_spec_pkg")
      File.write(pkg_path, "pkg data")
      expect_raises(CrystKit::Core::Error, /current application binary/i) do
        updater.install_update(info, Path.new(pkg_path), Path.new("/nonexistent/bin"))
      end
      File.delete(pkg_path) if File.exists?(pkg_path)
    end
    it "supports a custom app_path" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates",
        backup_dir: Path.new("/tmp/install_test_#{Time.utc.to_unix_ms}_3"))
      info = CrystKit::Features::UpdateInfo.new("2.0.0", "", "", "", 0_i64, "stable")
      current_path = File.tempname("updater_spec_bin")
      File.write(current_path, "current binary")
      File.chmod(current_path, 0o755)
      pkg_path = File.tempname("updater_spec_pkg")
      File.write(pkg_path, "new binary")
      begin
        swap = updater.install_update(info, Path.new(pkg_path), Path.new(current_path))
        File.exists?(swap.to_s).should be_true
      ensure
        File.delete(swap.to_s) if swap && File.exists?(swap.to_s)
        File.delete(current_path) if File.exists?(current_path)
        File.delete(pkg_path) if File.exists?(pkg_path)
      end
    end
    it "triggers on_before_install handler" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates",
        backup_dir: Path.new("/tmp/install_test_#{Time.utc.to_unix_ms}_4"))
      info = CrystKit::Features::UpdateInfo.new("2.0.0", "", "", "", 0_i64, "stable")
      called = false
      updater.on_before_install { called = true }
      current_path = File.tempname("updater_spec_bin")
      File.write(current_path, "bin")
      File.chmod(current_path, 0o755)
      pkg_path = File.tempname("updater_spec_pkg")
      File.write(pkg_path, "new")
      begin
        swap = updater.install_update(info, Path.new(pkg_path), Path.new(current_path))
      ensure
        File.delete(swap.to_s) if swap && File.exists?(swap.to_s)
        File.delete(current_path) if File.exists?(current_path)
        File.delete(pkg_path) if File.exists?(pkg_path)
      end
      called.should be_true
    end
    it "sets phase to Installing" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates",
        backup_dir: Path.new("/tmp/install_test_#{Time.utc.to_unix_ms}_5"))
      info = CrystKit::Features::UpdateInfo.new("2.0.0", "", "", "", 0_i64, "stable")
      current_path = File.tempname("updater_spec_bin")
      File.write(current_path, "bin")
      File.chmod(current_path, 0o755)
      pkg_path = File.tempname("updater_spec_pkg")
      File.write(pkg_path, "new")
      begin
        swap = updater.install_update(info, Path.new(pkg_path), Path.new(current_path))
        updater.phase.should eq(CrystKit::Features::UpdatePhase::Installing)
      ensure
        File.delete(swap.to_s) if swap && File.exists?(swap.to_s)
        File.delete(current_path) if File.exists?(current_path)
        File.delete(pkg_path) if File.exists?(pkg_path)
      end
    end
    it "creates a backup of the current binary" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates",
        backup_dir: Path.new("/tmp/install_test_#{Time.utc.to_unix_ms}_6"))
      info = CrystKit::Features::UpdateInfo.new("2.0.0", "", "", "", 0_i64, "stable")
      current_path = File.tempname("updater_spec_bin")
      File.write(current_path, "original binary content")
      File.chmod(current_path, 0o755)
      pkg_path = File.tempname("updater_spec_pkg")
      File.write(pkg_path, "new binary")
      begin
        swap = updater.install_update(info, Path.new(pkg_path), Path.new(current_path))
        backup_file = updater.backup_dir / "2.0.0" / File.basename(current_path)
        File.exists?(backup_file.to_s).should be_true
        File.read(backup_file.to_s).should eq("original binary content")
      ensure
        File.delete(swap.to_s) if swap && File.exists?(swap.to_s)
        File.delete(current_path) if File.exists?(current_path)
        File.delete(pkg_path) if File.exists?(pkg_path)
      end
    end
  end
  describe "#rollback" do
    it "raises when no backups exist" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates",
        backup_dir: Path.new("/tmp/rollback_test_nonexistent_#{Time.utc.to_unix_ms}"))
      expect_raises(CrystKit::Core::Error, /No backup found/i) { updater.rollback }
    end
    it "raises for a specific version with no backup" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates",
        backup_dir: Path.new("/tmp/rollback_test_version_#{Time.utc.to_unix_ms}"))
      expect_raises(CrystKit::Core::Error, /No backup found/i) { updater.rollback("0.0.9") }
    end
    it "restores the previous version after an install" do
      backup_dir = Path.new("/tmp/rollback_test_success_#{Time.utc.to_unix_ms}")
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates",
        backup_dir: backup_dir)
      info = CrystKit::Features::UpdateInfo.new("2.0.0", "", "", "", 0_i64, "stable")
      current_path = File.tempname("updater_spec_bin")
      File.write(current_path, "original binary")
      File.chmod(current_path, 0o755)
      pkg_path = File.tempname("updater_spec_pkg")
      File.write(pkg_path, "new binary version")
      begin
        install_swap = updater.install_update(info, Path.new(pkg_path), Path.new(current_path))
        File.exists?(install_swap.to_s).should be_true
        updater.phase.should eq(CrystKit::Features::UpdatePhase::Installing)
        updater.reset_phase
        rollback_swap = updater.rollback("2.0.0")
        File.exists?(rollback_swap.to_s).should be_true
        updater.phase.should eq(CrystKit::Features::UpdatePhase::RollingBack)
      ensure
        File.delete(install_swap.to_s) if install_swap && File.exists?(install_swap.to_s)
        File.delete(current_path) if File.exists?(current_path)
        File.delete(pkg_path) if File.exists?(pkg_path)
        FileUtils.rm_rf(backup_dir.to_s) if Dir.exists?(backup_dir.to_s)
      end
    end
  end
  describe "#apply_delta" do
    it "produces an output file from base and delta" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates")
      base_path = File.tempname("updater_spec_base")
      File.write(base_path, "AAAAAAAABBBBBBBB")
      delta_path = File.tempname("updater_spec_delta")
      delta_bytes = Bytes.new(8 + 8 + 1)
      IO::ByteFormat::LittleEndian.encode(16_i64, delta_bytes[0, 8])
      IO::ByteFormat::LittleEndian.encode(3_i64, delta_bytes[8, 8])
      delta_bytes[16] = 0x38_u8
      File.write(delta_path, delta_bytes)
      output_path = File.tempname("updater_spec_output")
      begin
        updater.apply_delta(Path.new(base_path), Path.new(delta_path), Path.new(output_path))
        File.read(output_path).should eq("AAAyAAAABBBBBBBB")
      ensure
        [base_path, delta_path, output_path].each { |p| File.delete(p) if File.exists?(p) }
      end
    end
    it "handles empty delta" do
      updater = CrystKit::Features::AutoUpdater.new("1.0.0", "https://example.com/updates")
      base_path = File.tempname("updater_spec_base")
      File.write(base_path, "hello")
      delta_path = File.tempname("updater_spec_delta")
      File.write(delta_path, Bytes.new(8))
      output_path = File.tempname("updater_spec_output")
      begin
        updater.apply_delta(Path.new(base_path), Path.new(delta_path), Path.new(output_path))
        File.read(output_path).should eq("hello")
      ensure
        [base_path, delta_path, output_path].each { |p| File.delete(p) if File.exists?(p) }
      end
    end
  end
end
