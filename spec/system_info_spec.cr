require "./spec_helper"
require "../src/features/system_info"

private class SystemInfoSpecProvider < CrystKit::Features::SystemInfo::Provider
  getter filesystem_paths = [] of String
  getter removable_paths = [] of String

  def os : CrystKit::Features::OSInfo
    CrystKit::Features::OSInfo.new("TestOS", "1.2.3")
  end

  def architecture : CrystKit::Features::Architecture
    CrystKit::Features::Architecture::ARM64
  end

  def locale : CrystKit::Features::LocaleInfo
    CrystKit::Features::LocaleInfo.new("en-GB", "en")
  end

  def hostname : String
    "test-host"
  end

  def cpu : CrystKit::Features::CPUInfo
    CrystKit::Features::CPUInfo.new(8, "Test CPU", 3.2)
  end

  def memory : CrystKit::Features::MemoryInfo
    CrystKit::Features::MemoryInfo.new(16_000_i64, 6_000_i64, 10_000_i64)
  end

  def filesystem(path : String) : CrystKit::Features::DiskInfo
    @filesystem_paths << path
    CrystKit::Features::DiskInfo.new(100_000_i64, 40_000_i64, 60_000_i64)
  end

  def removable?(path : String) : Bool
    @removable_paths << path
    path == "/media/usb"
  end

  def volumes : Array(CrystKit::Features::VolumeInfo)
    [
      CrystKit::Features::VolumeInfo.new("Data", "/data", 100_000_i64, 40_000_i64, false),
      CrystKit::Features::VolumeInfo.new("USB", "/media/usb", 20_000_i64, 15_000_i64, true),
    ]
  end

  def network_interfaces : Array(CrystKit::Features::NetworkInterface)
    [CrystKit::Features::NetworkInterface.new("eth0", "192.0.2.10", "00:11:22:33:44:55")]
  end

  def displays : Array(CrystKit::Features::Display)
    [CrystKit::Features::Display.new(7, 1920, 1080, 2.0, true)]
  end

  def home_directory : String
    "/home/tester"
  end

  def directories : CrystKit::Features::AppDataDirectories
    CrystKit::Features::AppDataDirectories.new(
      "/home/tester/.local/share",
      "/home/tester/.config",
      "/home/tester/.cache",
      "/usr/share",
    )
  end
end

private class EmptySystemInfoSpecProvider < SystemInfoSpecProvider
  def volumes : Array(CrystKit::Features::VolumeInfo)
    [] of CrystKit::Features::VolumeInfo
  end

  def network_interfaces : Array(CrystKit::Features::NetworkInterface)
    [] of CrystKit::Features::NetworkInterface
  end

  def displays : Array(CrystKit::Features::Display)
    [] of CrystKit::Features::Display
  end
end

describe CrystKit::Features::SystemInfo do
  it "delegates host identity snapshots to its provider" do
    info = CrystKit::Features::SystemInfo.new(SystemInfoSpecProvider.new)

    info.os_info.should eq(CrystKit::Features::OSInfo.new("TestOS", "1.2.3"))
    info.architecture.should eq(CrystKit::Features::Architecture::ARM64)
    info.locale_info.should eq(CrystKit::Features::LocaleInfo.new("en-GB", "en"))
    info.hostname.should eq("test-host")
    info.cpu_info.should eq(CrystKit::Features::CPUInfo.new(8, "Test CPU", 3.2))
    info.memory_info.should eq(CrystKit::Features::MemoryInfo.new(16_000_i64, 6_000_i64, 10_000_i64))
  end

  it "passes paths to filesystem and removability queries" do
    provider = SystemInfoSpecProvider.new
    info = CrystKit::Features::SystemInfo.new(provider)

    info.disk_info("/workspace").should eq(CrystKit::Features::DiskInfo.new(100_000_i64, 40_000_i64, 60_000_i64))
    info.ejectable?("/media/usb").should be_true
    info.ejectable?("/data").should be_false
    provider.filesystem_paths.should eq(["/workspace"])
    provider.removable_paths.should eq(["/media/usb", "/data"])
  end

  it "delegates collection snapshots without adding synthetic entries" do
    info = CrystKit::Features::SystemInfo.new(SystemInfoSpecProvider.new)

    info.list_mounts.map(&.name).should eq(["Data", "USB"])
    info.network_interfaces.map(&.name).should eq(["eth0"])
    displays = info.display_info
    displays.size.should eq(1)
    displays.first.id.should eq(7)
    displays.first.primary?.should be_true
  end

  it "preserves empty collections from the provider" do
    info = CrystKit::Features::SystemInfo.new(EmptySystemInfoSpecProvider.new)
    info.list_mounts.should be_empty
    info.network_interfaces.should be_empty
    info.display_info.should be_empty
  end

  it "delegates home and application-directory queries" do
    info = CrystKit::Features::SystemInfo.new(SystemInfoSpecProvider.new)

    info.home_directory.should eq("/home/tester")
    directories = info.app_data_directories
    directories.data.should eq("/home/tester/.local/share")
    directories.config.should eq("/home/tester/.config")
    directories.cache.should eq("/home/tester/.cache")
    directories.system_data.should eq("/usr/share")
  end

  it "reads application build metadata from the environment" do
    original_version = ENV["APP_VERSION"]?
    original_build = ENV["APP_BUILD"]?
    original_time = ENV["APP_BUILD_TIME"]?
    begin
      ENV["APP_VERSION"] = "2.4.1"
      ENV["APP_BUILD"] = "release-42"
      ENV["APP_BUILD_TIME"] = "2026-07-27T10:00:00Z"

      app = CrystKit::Features::SystemInfo.new(SystemInfoSpecProvider.new).app_info
      app.version.should eq("2.4.1")
      app.build.should eq("release-42")
      app.build_time.should eq("2026-07-27T10:00:00Z")
      app.to_s.should eq("2.4.1 (release-42)")
    ensure
      if original_version
        ENV["APP_VERSION"] = original_version
      else
        ENV.delete("APP_VERSION")
      end
      if original_build
        ENV["APP_BUILD"] = original_build
      else
        ENV.delete("APP_BUILD")
      end
      if original_time
        ENV["APP_BUILD_TIME"] = original_time
      else
        ENV.delete("APP_BUILD_TIME")
      end
    end
  end

  it "uses application metadata defaults" do
    original_version = ENV["APP_VERSION"]?
    original_build = ENV["APP_BUILD"]?
    original_time = ENV["APP_BUILD_TIME"]?
    begin
      ENV.delete("APP_VERSION")
      ENV.delete("APP_BUILD")
      ENV.delete("APP_BUILD_TIME")

      app = CrystKit::Features::SystemInfo.new(SystemInfoSpecProvider.new).app_info
      app.version.should eq("0.0.0")
      app.build.should eq("development")
      app.build_time.should be_nil
    ensure
      if original_version
        ENV["APP_VERSION"] = original_version
      else
        ENV.delete("APP_VERSION")
      end
      if original_build
        ENV["APP_BUILD"] = original_build
      else
        ENV.delete("APP_BUILD")
      end
      if original_time
        ENV["APP_BUILD_TIME"] = original_time
      else
        ENV.delete("APP_BUILD_TIME")
      end
    end
  end
end
