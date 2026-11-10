require "./spec_helper"
require "../src/features/process"

private def process_caps : CrystKit::Security::Context
  caps = CrystKit::Security::CapabilitySystem.new
  caps.grant("process:spawn")
  caps.grant("process:kill")
  SpecHelpers.security_context(caps, ["process:spawn", "process:kill"], execute_root: true)
end

private def spawn_only_caps : CrystKit::Security::Context
  caps = CrystKit::Security::CapabilitySystem.new
  caps.grant("process:spawn")
  SpecHelpers.security_context(caps, ["process:spawn", "process:kill"], execute_root: true)
end

describe CrystKit::Features::ProcessManager do
  describe "process spawning" do
    it "spawns a process and returns a ChildProcess with a valid PID" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("echo", "hello")
      child = manager.spawn(cmd, args)
      child.pid.should be > 0
      child.wait
    end
    it "captures stdout from the child process" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("echo", "hello stdout")
      child = manager.spawn(cmd, args)
      child.wait
      child.stdout_output.strip.should eq("hello stdout")
    end
    it "captures stderr from the child process" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("echo-err", "error_line")
      child = manager.spawn(cmd, args)
      child.wait
      child.stderr_output.strip.should eq("error_line")
    end
    it "captures both stdout and stderr independently" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("mixed", "out_line", "err_line")
      child = manager.spawn(cmd, args)
      child.wait
      child.stdout_output.strip.should eq("out_line")
      child.stderr_output.strip.should eq("err_line")
    end
    it "tracks the spawned process by PID" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("sleep", "10")
      child = manager.spawn(cmd, args)
      manager.tracked_pids.should contain(child.pid)
      child.kill
      child.wait
    end
    it "raises SecurityError when process:spawn capability is missing" do
      caps = CrystKit::Security::CapabilitySystem.new
      manager = CrystKit::Features::ProcessManager.new(SpecHelpers.security_context(caps, ["process:spawn", "process:kill"], execute_root: true))
      expect_raises(CrystKit::Core::SecurityError, /Missing capability: process:spawn/) do
        manager.spawn("anything", ["test"])
      end
    end
    it "logs a capability violation when process:spawn is missing" do
      caps = CrystKit::Security::CapabilitySystem.new
      manager = CrystKit::Features::ProcessManager.new(SpecHelpers.security_context(caps, ["process:spawn", "process:kill"], execute_root: true))
      begin
        manager.spawn("anything", ["test"])
      rescue CrystKit::Core::SecurityError
      end
      caps.violations.size.should eq(1)
      caps.violations[0].capability.should eq("process:spawn")
    end
    it "raises FileSystemError when the command is not found" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      expect_raises(CrystKit::Core::FileSystemError) do
        manager.spawn("__nonexistent_command_xyz__")
      end
    end
    it "spawns a process with no arguments" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("exit", "0")
      child = manager.spawn(cmd, args)
      exit_code = child.wait
      exit_code.should eq(0)
    end
    it "spawns a process with multiple arguments" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("echo", "foo", "bar", "baz")
      child = manager.spawn(cmd, args)
      child.wait
      child.stdout_output.strip.should eq("foo bar baz")
    end
  end
  describe "stdin writing" do
    it "sends data to child process stdin" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("cat")
      child = manager.spawn(cmd, args)
      child.write_stdin("hello from stdin\n")
      child.close_stdin
      child.wait
      child.stdout_output.strip.should eq("hello from stdin")
    end
    it "raises an error when writing to stdin after it is closed" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("cat")
      child = manager.spawn(cmd, args)
      child.close_stdin
      child.wait
      expect_raises(CrystKit::Core::FileSystemError) do
        child.write_stdin("should fail")
      end
    end
  end
  describe "exit event" do
    it "emits exit event with exit code 0 on success" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("exit", "0")
      child = manager.spawn(cmd, args)
      received_code = -1
      child.on_exit { |code| received_code = code }
      child.wait
      received_code.should eq(0)
    end
    it "emits exit event with non-zero exit code on failure" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("exit", "42")
      child = manager.spawn(cmd, args)
      received_code = -1
      child.on_exit { |code| received_code = code }
      child.wait
      received_code.should eq(42)
    end
    it "calls multiple exit handlers in registration order" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("exit", "0")
      child = manager.spawn(cmd, args)
      order = [] of Int32
      child.on_exit { |_| order << 1 }
      child.on_exit { |_| order << 2 }
      child.on_exit { |_| order << 3 }
      child.wait
      order.should eq([1, 2, 3])
    end
  end
  describe "process termination" do
    it "terminates a running process gracefully via manager" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("sleep", "60")
      child = manager.spawn(cmd, args)
      child.running?.should be_true
      manager.terminate(child.pid)
      sleep 100.milliseconds
      child.wait
      child.running?.should be_false
    end
    it "kills a running process forcefully via manager" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("sleep", "60")
      child = manager.spawn(cmd, args)
      child.running?.should be_true
      manager.kill(child.pid)
      sleep 100.milliseconds
      child.wait
      child.running?.should be_false
    end
    it "raises SecurityError when process:kill capability is missing for terminate" do
      caps = spawn_only_caps
      manager = CrystKit::Features::ProcessManager.new(caps)
      cmd, args = SpecHelpers.test_cmd("sleep", "60")
      child = manager.spawn(cmd, args)
      expect_raises(CrystKit::Core::SecurityError, /Missing capability: process:kill/) do
        manager.terminate(child.pid)
      end
      child.kill
      child.wait
    end
    it "raises SecurityError when process:kill capability is missing for kill" do
      caps = spawn_only_caps
      manager = CrystKit::Features::ProcessManager.new(caps)
      cmd, args = SpecHelpers.test_cmd("sleep", "60")
      child = manager.spawn(cmd, args)
      expect_raises(CrystKit::Core::SecurityError, /Missing capability: process:kill/) do
        manager.kill(child.pid)
      end
      child.kill
      child.wait
    end
    it "raises FileSystemError when terminating an untracked PID" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      expect_raises(CrystKit::Core::FileSystemError, /No tracked process/) do
        manager.terminate(999999_i64)
      end
    end
    it "raises FileSystemError when killing an untracked PID" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      expect_raises(CrystKit::Core::FileSystemError, /No tracked process/) do
        manager.kill(999999_i64)
      end
    end
    it "terminates a process directly via ChildProcess#terminate" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("sleep", "60")
      child = manager.spawn(cmd, args)
      child.running?.should be_true
      child.terminate
      sleep 100.milliseconds
      child.wait
      child.running?.should be_false
    end
    it "kills a process directly via ChildProcess#kill" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("sleep", "60")
      child = manager.spawn(cmd, args)
      child.running?.should be_true
      child.kill
      sleep 100.milliseconds
      child.wait
      child.running?.should be_false
    end
  end
  describe "environment variables" do
    it "passes custom environment variables to the child process" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      options = CrystKit::Features::SpawnOptions.new(
        env: {"MY_TEST_VAR" => "hello_env"}
      )
      cmd, args = SpecHelpers.test_cmd("print-env", "MY_TEST_VAR")
      child = manager.spawn(cmd, args, options)
      child.wait
      child.stdout_output.strip.should eq("hello_env")
    end
    it "inherits parent environment by default" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("print-env", "PATH")
      child = manager.spawn(cmd, args)
      child.wait
      child.stdout_output.strip.should_not be_empty
    end
    it "clears the environment when clear_env is true" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      options = CrystKit::Features::SpawnOptions.new(
        env: {"ONLY_VAR" => "only_value"},
        clear_env: true
      )
      cmd, args = SpecHelpers.test_cmd(
        "print-env-default",
        "ONLY_VAR", "missing",
        "HOME", "cleared"
      )
      child = manager.spawn(cmd, args, options)
      child.wait
      output = child.stdout_output.strip
      output.should eq("only_value:cleared")
    end
    it "merges custom env vars with inherited environment" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      options = CrystKit::Features::SpawnOptions.new(
        env: {"CUSTOM_VAR" => "custom_value"}
      )
      cmd, args = SpecHelpers.test_cmd("print-env", "CUSTOM_VAR")
      child = manager.spawn(cmd, args, options)
      child.wait
      child.stdout_output.strip.should eq("custom_value")
    end
  end
  describe "working directory" do
    it "sets the working directory for the child process" do
      SpecHelpers.with_temp_dir do |dir|
        manager = CrystKit::Features::ProcessManager.new(process_caps)
        options = CrystKit::Features::SpawnOptions.new(working_dir: dir)
        cmd, args = SpecHelpers.test_cmd("pwd")
        child = manager.spawn(cmd, args, options)
        child.wait
        actual = File.realpath(child.stdout_output.strip)
        expected = File.realpath(dir)
        actual.should eq(expected)
      end
    end
    it "uses the current working directory when none is specified" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("pwd")
      child = manager.spawn(cmd, args)
      child.wait
      actual = File.realpath(child.stdout_output.strip)
      expected = File.realpath(Dir.current)
      actual.should eq(expected)
    end
    it "raises an error when the working directory does not exist" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      options = CrystKit::Features::SpawnOptions.new(working_dir: "/nonexistent_dir_xyz_12345")
      cmd, args = SpecHelpers.test_cmd("echo", "test")
      expect_raises(CrystKit::Core::FileSystemError) do
        manager.spawn(cmd, args, options)
      end
    end
  end
  describe "timeout handling" do
    it "kills the process when it exceeds the timeout" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      options = CrystKit::Features::SpawnOptions.new(timeout: 200.milliseconds)
      cmd, args = SpecHelpers.test_cmd("sleep", "60")
      child = manager.spawn(cmd, args, options)
      sleep 500.milliseconds
      child.wait
      child.running?.should be_false
    end
    it "does not kill the process when it completes before the timeout" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      options = CrystKit::Features::SpawnOptions.new(timeout: 5.seconds)
      cmd, args = SpecHelpers.test_cmd("echo", "fast")
      child = manager.spawn(cmd, args, options)
      exit_code = child.wait
      exit_code.should eq(0)
      child.stdout_output.strip.should eq("fast")
    end
  end
  describe "process tracking" do
    it "finds a tracked process by PID" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("sleep", "10")
      child = manager.spawn(cmd, args)
      found = manager.find(child.pid)
      found.should_not be_nil
      found.not_nil!.pid.should eq(child.pid)
      child.kill
      child.wait
    end
    it "returns nil for an untracked PID" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      manager.find(999999_i64).should be_nil
    end
    it "untracks a process after calling untrack" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd, args = SpecHelpers.test_cmd("exit", "0")
      child = manager.spawn(cmd, args)
      child.wait
      manager.untrack(child.pid)
      manager.find(child.pid).should be_nil
    end
    it "returns all tracked PIDs" do
      manager = CrystKit::Features::ProcessManager.new(process_caps)
      cmd1, args1 = SpecHelpers.test_cmd("sleep", "10")
      cmd2, args2 = SpecHelpers.test_cmd("sleep", "10")
      child1 = manager.spawn(cmd1, args1)
      child2 = manager.spawn(cmd2, args2)
      pids = manager.tracked_pids
      pids.should contain(child1.pid)
      pids.should contain(child2.pid)
      child1.kill
      child2.kill
      child1.wait
      child2.wait
    end
  end
end
describe CrystKit::Features::ChildProcess do
  describe "#running?" do
    it "returns true while the process is running" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("process:spawn")
      manager = CrystKit::Features::ProcessManager.new(SpecHelpers.security_context(caps, ["process:spawn", "process:kill"], execute_root: true))
      cmd, args = SpecHelpers.test_cmd("sleep", "10")
      child = manager.spawn(cmd, args)
      child.running?.should be_true
      child.kill
      sleep 100.milliseconds
      child.wait
    end
    it "returns false after the process has exited" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("process:spawn")
      manager = CrystKit::Features::ProcessManager.new(SpecHelpers.security_context(caps, ["process:spawn", "process:kill"], execute_root: true))
      cmd, args = SpecHelpers.test_cmd("exit", "0")
      child = manager.spawn(cmd, args)
      child.wait
      child.running?.should be_false
    end
  end
end
