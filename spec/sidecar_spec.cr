require "./spec_helper"
require "../src/features/sidecar"

private def sidecar_caps : CrystKit::Security::CapabilitySystem
  caps = CrystKit::Security::CapabilitySystem.new
  caps.grant("sidecar:execute")
  caps.grant("sidecar:spawn")
  caps
end

private def no_caps : CrystKit::Security::CapabilitySystem
  CrystKit::Security::CapabilitySystem.new
end

describe CrystKit::Features::TargetTriple do
  describe ".current" do
    it "returns a non-empty target triple string" do
      triple = CrystKit::Features::TargetTriple.current
      triple.should_not be_empty
      triple.should_not eq("unknown")
    end

    it "includes the architecture" do
      triple = CrystKit::Features::TargetTriple.current
      triple.should match(/aarch64|x86_64/)
    end

    it "includes the OS" do
      triple = CrystKit::Features::TargetTriple.current
      triple.should match(/darwin|linux|windows/)
    end
  end

  describe ".sidecar_filename" do
    it "appends triple suffix with no extension on non-Windows" do
      name = CrystKit::Features::TargetTriple.sidecar_filename("myapp", "x86_64-unknown-linux-gnu")
      name.should eq("myapp-x86_64-unknown-linux-gnu")
    end

    it "appends .exe extension for Windows triples" do
      name = CrystKit::Features::TargetTriple.sidecar_filename("myapp", "x86_64-pc-windows-msvc")
      name.should eq("myapp-x86_64-pc-windows-msvc.exe")
    end

    it "preserves the base name" do
      name = CrystKit::Features::TargetTriple.sidecar_filename("sidecar", "aarch64-apple-darwin")
      name.should start_with("sidecar-")
    end
  end
end

describe CrystKit::Features::SidecarResult do
  it "reports success when exit_code is 0" do
    result = CrystKit::Features::SidecarResult.new("", "", 0)
    result.success?.should be_true
  end

  it "reports failure when exit_code is non-zero" do
    result = CrystKit::Features::SidecarResult.new("", "", 1)
    result.success?.should be_false
  end
end

describe CrystKit::Features::SidecarManager do
  describe "#register" do
    it "registers a sidecar by name and path" do
      manager = CrystKit::Features::SidecarManager.new(sidecar_caps)
      manager.registered?("test").should be_false
      manager.register("test", "/some/path")
      manager.registered?("test").should be_true
    end

    it "lists registered sidecars" do
      manager = CrystKit::Features::SidecarManager.new(sidecar_caps)
      manager.register("a", "/a")
      manager.register("b", "/b")
      registered = manager.registered_sidecars
      registered.should contain("a")
      registered.should contain("b")
    end
  end

  describe "#execute" do
    it "executes a registered sidecar and captures stdout" do
      manager = CrystKit::Features::SidecarManager.new(sidecar_caps)
      cmd, args = SpecHelpers.test_cmd("echo", "sidecar output")
      manager.register("test_sidecar", cmd)

      result = manager.execute("test_sidecar", CrystKit::Features::SidecarOptions.new(args: args))

      result.stdout.strip.should eq("sidecar output")
      result.exit_code.should eq(0)
      result.success?.should be_true
    end

    it "captures stderr from the sidecar" do
      manager = CrystKit::Features::SidecarManager.new(sidecar_caps)
      cmd, args = SpecHelpers.test_cmd("echo-err", "error text")
      manager.register("err_sidecar", cmd)

      result = manager.execute("err_sidecar", CrystKit::Features::SidecarOptions.new(args: args))

      result.stderr.strip.should eq("error text")
    end

    it "returns non-zero exit code for failing sidecars" do
      manager = CrystKit::Features::SidecarManager.new(sidecar_caps)
      cmd, args = SpecHelpers.test_cmd("exit", "42")
      manager.register("fail_sidecar", cmd)

      result = manager.execute("fail_sidecar", CrystKit::Features::SidecarOptions.new(args: args))

      result.exit_code.should eq(42)
      result.success?.should be_false
    end

    it "raises SecurityError when sidecar:execute capability is missing" do
      manager = CrystKit::Features::SidecarManager.new(no_caps)
      manager.register("test", "/bin/echo")

      expect_raises(CrystKit::Core::SecurityError, /Missing capability: sidecar:execute/) do
        manager.execute("test")
      end
    end

    it "raises error when sidecar is not registered" do
      manager = CrystKit::Features::SidecarManager.new(sidecar_caps)

      expect_raises(CrystKit::Core::Error, /not registered/) do
        manager.execute("nonexistent")
      end
    end

    it "passes environment variables to the sidecar" do
      manager = CrystKit::Features::SidecarManager.new(sidecar_caps)
      cmd, args = SpecHelpers.test_cmd("print-env", "MY_TEST_VAR")
      manager.register("env_sidecar", cmd)

      opts = CrystKit::Features::SidecarOptions.new(args: args, env: {"MY_TEST_VAR" => "custom_value"})
      result = manager.execute("env_sidecar", opts)

      result.stdout.strip.should eq("custom_value")
    end

    it "enforces timeout and raises on expiry" do
      manager = CrystKit::Features::SidecarManager.new(sidecar_caps)
      cmd, args = SpecHelpers.test_cmd("sleep", "10")
      manager.register("sleepy", cmd)

      opts = CrystKit::Features::SidecarOptions.new(args: args, timeout: 100.milliseconds)

      expect_raises(CrystKit::Core::TimeoutError, /timed out/) do
        manager.execute("sleepy", opts)
      end
    end
  end

  describe "#execute with working directory" do
    it "uses the specified working directory" do
      manager = CrystKit::Features::SidecarManager.new(sidecar_caps)
      cmd, args = SpecHelpers.test_cmd("pwd")
      manager.register("pwd_sidecar", cmd)

      SpecHelpers.with_temp_dir do |dir|
        real_dir = File.realpath(dir)
        opts = CrystKit::Features::SidecarOptions.new(args: args, cwd: Path[real_dir])
        result = manager.execute("pwd_sidecar", opts)
        result.stdout.strip.should eq(real_dir)
      end
    end
  end
end
