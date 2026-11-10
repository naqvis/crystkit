WEBVIEW_TEST_CMD_SENTINEL = "--webview-test-cmd"
if ARGV.first? == WEBVIEW_TEST_CMD_SENTINEL
  args = ARGV[1..]
  subcmd = args.shift? || (STDERR.puts("test_cmd: missing subcommand"); exit 2)
  case subcmd
  when "exit"
    exit(args[0]?.try(&.to_i) || 0)
  when "echo"
    STDOUT.puts args.join(" ")
  else
    STDERR.puts "test_cmd: unknown subcommand #{subcmd.inspect}"
    exit 2
  end
  exit 0
end
require "spec"
require "file_utils"

module SpecHelpers
  def self.test_cmd(subcommand : String, args : Array(String) = [] of String) : {String, Array(String)}
    {Process.executable_path.not_nil!, [WEBVIEW_TEST_CMD_SENTINEL, subcommand] + args}
  end

  def self.test_cmd(subcommand : String, *args : String) : {String, Array(String)}
    test_cmd(subcommand, args.to_a)
  end

  def self.with_temp_dir(& : String ->)
    raw = File.tempname("crystkit_builder_spec")
    Dir.mkdir_p(raw)
    begin
      yield raw.gsub('\\', '/')
    ensure
      FileUtils.rm_rf(raw) if Dir.exists?(raw)
    end
  end
end

include SpecHelpers
