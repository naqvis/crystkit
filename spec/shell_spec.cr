require "./spec_helper"
require "../src/features/shell"

private def executor_with_caps : CrystKit::Features::ShellExecutor
  caps = CrystKit::Security::CapabilitySystem.new
  caps.grant("shell:execute")
  CrystKit::Features::ShellExecutor.new(SpecHelpers.security_context(caps, ["shell:execute"], execute_root: true))
end

private def executor_no_caps : CrystKit::Features::ShellExecutor
  caps = CrystKit::Security::CapabilitySystem.new
  CrystKit::Features::ShellExecutor.new(SpecHelpers.security_context(caps, ["shell:execute"], execute_root: true))
end

describe CrystKit::Features::ShellExecutor do
  describe "command execution and output capture" do
    it "executes a command and captures stdout" do
      cmd, args = SpecHelpers.test_cmd("echo", "hello world")
      result = executor_with_caps.execute(cmd, args)
      result.stdout.strip.should eq("hello world")
      result.exit_code.should eq(0)
      result.success?.should be_true
    end
    it "captures stderr output separately from stdout" do
      cmd, args = SpecHelpers.test_cmd("echo-err", "err_line")
      result = executor_with_caps.execute(cmd, args)
      result.stderr.strip.should eq("err_line")
      result.stdout.strip.should eq("")
      result.exit_code.should eq(0)
    end
    it "captures both stdout and stderr independently" do
      cmd, args = SpecHelpers.test_cmd("mixed", "out_line", "err_line")
      result = executor_with_caps.execute(cmd, args)
      result.stdout.strip.should eq("out_line")
      result.stderr.strip.should eq("err_line")
    end
    it "returns exit code 0 for successful commands" do
      cmd, args = SpecHelpers.test_cmd("exit", "0")
      result = executor_with_caps.execute(cmd, args)
      result.exit_code.should eq(0)
      result.success?.should be_true
    end
    it "returns non-zero exit code for failing commands" do
      cmd, args = SpecHelpers.test_cmd("exit", "1")
      result = executor_with_caps.execute(cmd, args)
      result.exit_code.should_not eq(0)
      result.success?.should be_false
    end
    it "returns the exact exit code set by the command" do
      cmd, args = SpecHelpers.test_cmd("exit", "42")
      result = executor_with_caps.execute(cmd, args)
      result.exit_code.should eq(42)
      result.success?.should be_false
    end
    it "executes a command with multiple arguments" do
      cmd, args = SpecHelpers.test_cmd("echo", "foo", "bar", "baz")
      result = executor_with_caps.execute(cmd, args)
      result.stdout.strip.should eq("foo bar baz")
      result.exit_code.should eq(0)
    end
    it "executes a command with no arguments" do
      cmd, args = SpecHelpers.test_cmd("exit", "0")
      result = executor_with_caps.execute(cmd, args)
      result.exit_code.should eq(0)
    end
    it "captures multi-line stdout output" do
      cmd, args = SpecHelpers.test_cmd("multiline", "line1", "line2", "line3")
      result = executor_with_caps.execute(cmd, args)
      lines = result.stdout.lines.map(&.chomp).reject(&.empty?)
      lines.should eq(["line1", "line2", "line3"])
    end
  end
  describe "timeout handling" do
    it "raises TimeoutError when command exceeds the timeout" do
      opts = CrystKit::Features::ShellOptions.new(timeout: 100.milliseconds)
      cmd, args = SpecHelpers.test_cmd("sleep", "10")
      expect_raises(CrystKit::Core::TimeoutError) do
        executor_with_caps.execute(cmd, args, opts)
      end
    end
    it "completes successfully when command finishes before timeout" do
      opts = CrystKit::Features::ShellOptions.new(timeout: 5.seconds)
      cmd, args = SpecHelpers.test_cmd("exit", "0")
      result = executor_with_caps.execute(cmd, args, opts)
      result.exit_code.should eq(0)
    end
    it "uses default 30-second timeout when none is specified" do
      opts = CrystKit::Features::ShellOptions.new
      opts.timeout.should eq(30.seconds)
    end
    it "allows nil timeout for commands with no time limit" do
      opts = CrystKit::Features::ShellOptions.new(timeout: nil)
      cmd, args = SpecHelpers.test_cmd("exit", "0")
      result = executor_with_caps.execute(cmd, args, opts)
      result.exit_code.should eq(0)
    end
  end
  describe "error handling" do
    it "raises FileSystemError when command is not found" do
      expect_raises(CrystKit::Core::FileSystemError) do
        executor_with_caps.execute("__nonexistent_command_xyz__")
      end
    end
    it "includes the command name in the FileSystemError message" do
      begin
        executor_with_caps.execute("__nonexistent_cmd_abc__")
        fail "Expected FileSystemError"
      rescue ex : CrystKit::Core::FileSystemError
        ex.message.not_nil!.should contain("__nonexistent_cmd_abc__")
      end
    end
    it "returns non-zero exit code for commands that fail" do
      cmd, args = SpecHelpers.test_cmd("exit", "1")
      result = executor_with_caps.execute(cmd, args)
      result.success?.should be_false
      result.exit_code.should eq(1)
    end
  end
  describe "argument sanitization" do
    it "passes arguments verbatim without shell interpretation" do
      cmd, args = SpecHelpers.test_cmd("echo", "hello; echo injected")
      result = executor_with_caps.execute(cmd, args)
      result.stdout.strip.should eq("hello; echo injected")
      result.exit_code.should eq(0)
    end
    it "treats shell pipe characters as literal argument text" do
      cmd, args = SpecHelpers.test_cmd("echo", "a | b")
      result = executor_with_caps.execute(cmd, args)
      result.stdout.strip.should eq("a | b")
    end
    it "treats shell redirection characters as literal argument text" do
      cmd, args = SpecHelpers.test_cmd("echo", "a > b")
      result = executor_with_caps.execute(cmd, args)
      result.stdout.strip.should eq("a > b")
    end
    it "treats backtick command substitution as literal text" do
      cmd, args = SpecHelpers.test_cmd("echo", "`whoami`")
      result = executor_with_caps.execute(cmd, args)
      result.stdout.strip.should eq("`whoami`")
    end
    it "treats dollar-sign variable expansion as literal text" do
      cmd, args = SpecHelpers.test_cmd("echo", "$HOME")
      result = executor_with_caps.execute(cmd, args)
      result.stdout.strip.should eq("$HOME")
    end
    it "strips null bytes from arguments" do
      cmd, args = SpecHelpers.test_cmd("echo", "hel\0lo")
      result = executor_with_caps.execute(cmd, args)
      result.stdout.strip.should eq("hello")
    end
    it "handles arguments with spaces correctly" do
      cmd, args = SpecHelpers.test_cmd("echo", "hello world", "foo bar")
      result = executor_with_caps.execute(cmd, args)
      result.stdout.strip.should eq("hello world foo bar")
    end
    it "handles arguments with special characters safely" do
      cmd, args = SpecHelpers.test_cmd("echo", "--flag=value", "-x")
      result = executor_with_caps.execute(cmd, args)
      result.stdout.strip.should eq("--flag=value -x")
    end
  end
  describe "working directory specification" do
    it "executes command in the specified working directory" do
      SpecHelpers.with_temp_dir do |dir|
        opts = CrystKit::Features::ShellOptions.new(cwd: Path.new(dir))
        cmd, args = SpecHelpers.test_cmd("pwd")
        result = executor_with_caps.execute(cmd, args, opts)
        actual = File.realpath(result.stdout.strip)
        expected = File.realpath(dir)
        actual.should eq(expected)
      end
    end
    it "uses the current directory when no cwd is specified" do
      cmd, args = SpecHelpers.test_cmd("pwd")
      result = executor_with_caps.execute(cmd, args)
      result.stdout.strip.should_not be_empty
      result.exit_code.should eq(0)
    end
    it "can read files relative to the working directory" do
      SpecHelpers.with_temp_dir do |dir|
        File.write(File.join(dir, "test.txt"), "hello from file")
        opts = CrystKit::Features::ShellOptions.new(cwd: Path.new(dir))
        cmd, args = SpecHelpers.test_cmd("cat-file", "test.txt")
        result = executor_with_caps.execute(cmd, args, opts)
        result.stdout.should eq("hello from file")
        result.exit_code.should eq(0)
      end
    end
  end
  describe "environment variable passing" do
    it "passes custom environment variables to the command" do
      opts = CrystKit::Features::ShellOptions.new(
        env: {"MY_TEST_VAR" => "hello_env"}
      )
      cmd, args = SpecHelpers.test_cmd("print-env", "MY_TEST_VAR")
      result = executor_with_caps.execute(cmd, args, opts)
      result.stdout.strip.should eq("hello_env")
      result.exit_code.should eq(0)
    end
    it "merges custom env vars with the existing process environment" do
      opts = CrystKit::Features::ShellOptions.new(
        env: {"CUSTOM_VAR" => "custom_value"}
      )
      cmd, args = SpecHelpers.test_cmd("print-env", "CUSTOM_VAR")
      result = executor_with_caps.execute(cmd, args, opts)
      result.stdout.strip.should eq("custom_value")
    end
    it "can override existing environment variables" do
      opts = CrystKit::Features::ShellOptions.new(
        env: {"HOME" => "/tmp/fake_home"}
      )
      cmd, args = SpecHelpers.test_cmd("print-env", "HOME")
      result = executor_with_caps.execute(cmd, args, opts)
      result.stdout.strip.should eq("/tmp/fake_home")
    end
    it "passes multiple environment variables" do
      opts = CrystKit::Features::ShellOptions.new(
        env: {"VAR_A" => "alpha", "VAR_B" => "beta"}
      )
      cmd, args = SpecHelpers.test_cmd("print-env", "VAR_A", "VAR_B")
      result = executor_with_caps.execute(cmd, args, opts)
      result.stdout.strip.should eq("alpha beta")
    end
    it "inherits parent environment when no env overrides are given" do
      cmd, args = SpecHelpers.test_cmd("print-env", "PATH")
      result = executor_with_caps.execute(cmd, args)
      result.stdout.strip.should_not be_empty
    end
  end
  describe "capability-based permission enforcement" do
    it "raises SecurityError when shell:execute capability is missing" do
      expect_raises(CrystKit::Core::SecurityError, /Missing capability: shell:execute/) do
        executor_no_caps.execute("anything", ["test"])
      end
    end
    it "logs a capability violation when shell:execute is missing" do
      caps = CrystKit::Security::CapabilitySystem.new
      executor = CrystKit::Features::ShellExecutor.new(SpecHelpers.security_context(caps, ["shell:execute"], execute_root: true))
      begin
        executor.execute("anything", ["test"])
      rescue CrystKit::Core::SecurityError
      end
      caps.violations.size.should eq(1)
      caps.violations[0].capability.should eq("shell:execute")
    end
    it "executes successfully when shell:execute capability is granted" do
      cmd, args = SpecHelpers.test_cmd("echo", "ok")
      result = executor_with_caps.execute(cmd, args)
      result.exit_code.should eq(0)
    end
    it "raises SecurityError before attempting to run the command" do
      expect_raises(CrystKit::Core::SecurityError) do
        executor_no_caps.execute("__nonexistent__")
      end
    end
  end
  describe "asynchronous execution" do
    it "executes a command asynchronously and calls the block with the result" do
      result_channel = Channel(CrystKit::Features::ShellResult).new(1)
      cmd, args = SpecHelpers.test_cmd("echo", "async_output")
      executor_with_caps.execute_async(cmd, args) do |result|
        result_channel.send(result)
      end
      result = result_channel.receive
      result.stdout.strip.should eq("async_output")
      result.exit_code.should eq(0)
    end
    it "returns immediately without blocking the caller" do
      started_at = Time.instant
      done_channel = Channel(Nil).new(1)
      cmd, args = SpecHelpers.test_cmd("sleep", "0.1")
      executor_with_caps.execute_async(cmd, args) do |_result|
        done_channel.send(nil)
      end
      elapsed = Time.instant - started_at
      elapsed.should be < 50.milliseconds
      done_channel.receive
    end
    it "captures stdout in async execution" do
      result_channel = Channel(CrystKit::Features::ShellResult).new(1)
      cmd, args = SpecHelpers.test_cmd("mixed", "async_stdout", "async_stderr")
      executor_with_caps.execute_async(cmd, args) do |result|
        result_channel.send(result)
      end
      result = result_channel.receive
      result.stdout.strip.should eq("async_stdout")
      result.stderr.strip.should eq("async_stderr")
    end
    it "reports non-zero exit codes in async execution" do
      result_channel = Channel(CrystKit::Features::ShellResult).new(1)
      cmd, args = SpecHelpers.test_cmd("exit", "7")
      executor_with_caps.execute_async(cmd, args) do |result|
        result_channel.send(result)
      end
      result = result_channel.receive
      result.exit_code.should eq(7)
      result.success?.should be_false
    end
    it "supports working directory and env vars in async execution" do
      result_channel = Channel(CrystKit::Features::ShellResult).new(1)
      opts = CrystKit::Features::ShellOptions.new(
        env: {"ASYNC_VAR" => "async_value"}
      )
      cmd, args = SpecHelpers.test_cmd("print-env", "ASYNC_VAR")
      executor_with_caps.execute_async(cmd, args, opts) do |result|
        result_channel.send(result)
      end
      result = result_channel.receive
      result.stdout.strip.should eq("async_value")
    end
  end
end
