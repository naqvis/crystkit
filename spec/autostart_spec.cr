require "./spec_helper"
require "../src/features/autostart"

private class AutostartSpecProvider < CrystKit::Features::Autostart::Provider
  getter entries = [] of NativeDesktop::AutostartEntry
  getter disabled = [] of String
  property? registered = false
  property enable_error : Exception?
  property disable_error : Exception?
  property status_error : Exception?

  def enable(entry : NativeDesktop::AutostartEntry) : Nil
    if error = @enable_error
      raise error
    end
    @entries << entry
    @registered = true
  end

  def disable(name : String) : Nil
    if error = @disable_error
      raise error
    end
    @disabled << name
    @registered = false
  end

  def enabled?(name : String) : Bool
    if error = @status_error
      raise error
    end
    @registered
  end
end

describe CrystKit::Features::AutostartOptions do
  it "stores launch arguments, minimized mode, and delay" do
    options = CrystKit::Features::AutostartOptions.new(
      args: ["--profile", "work"],
      minimized: true,
      delay: 5.seconds,
    )

    options.args.should eq(["--profile", "work"])
    options.minimized?.should be_true
    options.delay.should eq(5.seconds)
  end
end

describe CrystKit::Features::Autostart do
  app_path = Path[Process.executable_path || PROGRAM_NAME].expand

  it "stores the application identity" do
    autostart = CrystKit::Features::Autostart.new("Example", app_path, AutostartSpecProvider.new)

    autostart.app_name.should eq("Example")
    autostart.app_path.should eq(app_path)
  end

  it "maps every option into the native service entry" do
    provider = AutostartSpecProvider.new
    autostart = CrystKit::Features::Autostart.new("Example", app_path, provider)

    autostart.enable(
      CrystKit::Features::AutostartOptions.new(
        args: ["--config", "settings.json"],
        minimized: true,
        delay: 12.seconds,
      )
    )

    entry = provider.entries.first
    entry.name.should eq("Example")
    entry.executable.should eq(app_path)
    entry.arguments.should eq(["--config", "settings.json"])
    entry.minimized.should be_true
    entry.delay.should eq(12.seconds)
  end

  it "delegates registration status and disable by application name" do
    provider = AutostartSpecProvider.new
    autostart = CrystKit::Features::Autostart.new("Example", app_path, provider)

    autostart.enabled?.should be_false
    autostart.enable
    autostart.enabled?.should be_true
    autostart.disable
    autostart.enabled?.should be_false
    provider.disabled.should eq(["Example"])
  end

  it "wraps enable failures with a stable CrystKit error" do
    provider = AutostartSpecProvider.new
    provider.enable_error = IO::Error.new("registration failed")
    autostart = CrystKit::Features::Autostart.new("Example", app_path, provider)

    error = expect_raises(CrystKit::Core::Error) { autostart.enable }
    error.code.should eq("AUTOSTART_REGISTER_FAILED")
    error.message.to_s.should contain("Example")
    error.message.to_s.should contain("registration failed")
  end

  it "wraps disable failures with a stable CrystKit error" do
    provider = AutostartSpecProvider.new
    provider.disable_error = IO::Error.new("removal failed")
    autostart = CrystKit::Features::Autostart.new("Example", app_path, provider)

    error = expect_raises(CrystKit::Core::Error) { autostart.disable }
    error.code.should eq("AUTOSTART_UNREGISTER_FAILED")
    error.message.to_s.should contain("Example")
    error.message.to_s.should contain("removal failed")
  end

  it "returns false when the provider cannot read registration status" do
    provider = AutostartSpecProvider.new
    provider.status_error = IO::Error.new("status failed")
    autostart = CrystKit::Features::Autostart.new("Example", app_path, provider)

    autostart.enabled?.should be_false
  end
end
