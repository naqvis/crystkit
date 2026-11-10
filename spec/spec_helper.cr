WEBVIEW_TEST_CMD_SENTINEL = "--webview-test-cmd"
if ARGV.first? == WEBVIEW_TEST_CMD_SENTINEL
  args = ARGV[1..]
  subcmd = args.shift? || (STDERR.puts("test_cmd: missing subcommand"); exit 2)
  case subcmd
  when "echo"
    STDOUT.puts args.join(" ")
  when "echo-err"
    STDERR.puts args.join(" ")
  when "mixed"
    STDOUT.puts args[0]? || ""
    STDERR.puts args[1]? || ""
  when "exit"
    exit(args[0]?.try(&.to_i) || 0)
  when "sleep"
    sleep((args[0]?.try(&.to_f) || 0.0).seconds)
  when "cat"
    IO.copy(STDIN, STDOUT)
  when "cat-file"
    File.open(args[0]) { |f| IO.copy(f, STDOUT) }
  when "pwd"
    STDOUT.puts Dir.current
  when "print-env"
    STDOUT.puts args.map { |n| ENV[n]? || "" }.join(" ")
  when "print-env-default"
    parts = [] of String
    args.each_slice(2, reuse: false) do |pair|
      parts << (ENV[pair[0]]? || (pair[1]? || ""))
    end
    STDOUT.puts parts.join(":")
  when "multiline"
    args.each { |line| STDOUT.puts line }
  else
    STDERR.puts "test_cmd: unknown subcommand #{subcmd.inspect}"
    exit 2
  end
  exit 0
end
require "spec"
require "file_utils"
require "../src/crystkit"
require "../src/test/fake_window_backend"
require "../src/test/fake_clipboard_backend"
require "../src/test/fake_speech_backend"
require "../src/test/fake_theme_backend"
require "../src/test/fake_power_provider"
require "../src/test/fake_idle_provider"
require "../src/test/fake_cpu_provider"
require "../src/test/fake_dpi_provider"

require "../src/test/fake_toolbar_provider"
require "../src/test/fake_window_integration_backend"

module SpecHelpers
  def self.test_cmd(subcommand : String, args : Array(String) = [] of String) : {String, Array(String)}
    {Process.executable_path.not_nil!, [WEBVIEW_TEST_CMD_SENTINEL, subcommand] + args}
  end

  def self.test_cmd(subcommand : String, *args : String) : {String, Array(String)}
    test_cmd(subcommand, args.to_a)
  end

  def self.with_temp_dir(& : String ->)
    raw = File.tempname("webview_test")
    Dir.mkdir_p(raw)
    begin
      yield raw.gsub('\\', '/')
    ensure
      FileUtils.rm_rf(raw) if Dir.exists?(raw)
    end
  end

  # Builds an `App` whose window backend is `Test::FakeWindowBackend`,
  # so windows are created without a native webview (safe on headless
  # CI). Pass a block that yields the `storage_dir` string, mirroring
  # `with_temp_dir`.
  def self.with_fake_window_app(& : CrystKit::App ->)
    with_temp_dir do |dir|
      platform = CrystKit::Platform::Services.new(
        window: CrystKit::Test::FakeWindowBackend.new,
      )
      app = CrystKit::App.new(
        CrystKit::AppConfig.new(storage_dir: Path[dir]),
        platform: platform,
      )
      yield app
    end
  end

  def self.with_temp_file(content : String? = nil, & : String ->)
    file = File.tempname("webview_test")
    File.write(file, content || "")
    begin
      yield file
    ensure
      File.delete(file) if File.exists?(file)
    end
  end

  def self.with_env(key : String, value : String?, &)
    old = ENV[key]?
    if value
      ENV[key] = value
    else
      ENV.delete(key)
    end
    begin
      yield
    ensure
      if old
        ENV[key] = old
      else
        ENV.delete(key)
      end
    end
  end

  def self.wait_for(timeout : Time::Span = 5.seconds, &block : -> Bool)
    start = Time.instant
    loop do
      return true if block.call
      raise "Timeout waiting for condition" if Time.instant - start > timeout
      sleep 10.milliseconds
    end
  end

  def self.security_context(
    capabilities : CrystKit::Security::CapabilitySystem,
    resource_capabilities : Array(String) = [] of String,
    execute_root : Bool = false,
  ) : CrystKit::Security::Context
    context = CrystKit::Security::Context.new(capabilities)
    prefixes = resource_capabilities.map(&.split(':').first).uniq!
    prefixes.each do |prefix|
      case prefix
      when "http"
        context.resource_scopes["http"] = CrystKit::Security::Scopes::HttpScope.new(["*"])
      when "process"
        context.resource_scopes["process"] = CrystKit::Security::Scopes::ProcessScope.new(["*"])
      when "shell"
        context.resource_scopes["shell"] = CrystKit::Security::Scopes::ProcessScope.new(["*"])
      end
    end
    if execute_root
      persist_test_root(context.scopes, CrystKit::Security::Permission::Execute)
      persist_test_root(context.scopes, CrystKit::Security::Permission::Read)
      persist_test_root(context.scopes, CrystKit::Security::Permission::Write)
    end
    context
  end

  def self.persist_test_root(scopes : CrystKit::Security::ScopeManager, permission : CrystKit::Security::Permission) : Nil
    scopes.persist(Path[File::SEPARATOR.to_s], permission)
    scopes.persist(Path[Dir.tempdir], permission)
  end

  def self.capture_output(&)
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    original_stdout = STDOUT
    original_stderr = STDERR
    begin
      STDOUT.reopen(stdout)
      STDERR.reopen(stderr)
      yield
    ensure
      STDOUT.reopen(original_stdout)
      STDERR.reopen(original_stderr)
    end
    {stdout: stdout.to_s, stderr: stderr.to_s}
  end
end

def SpecHelpers.storage_config : CrystKit::AppConfig
  dir = File.tempname("crystkit_spec")
  Dir.mkdir_p(dir)
  CrystKit::AppConfig.new(
    identifier: "test.spec.#{Random.rand(100_000)}",
    storage_dir: Path[dir],
  )
end

include SpecHelpers
