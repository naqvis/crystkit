require "./spec_helper"
require "../src/app/app"
require "../src/plugins/builtins/fs"
require "../src/plugins/builtins/http"
require "../src/plugins/builtins/biometric"
require "../src/plugins/builtins/window"

describe "built-in IPC metadata policy" do
  it "keeps high-risk filesystem policy on the filesystem plugin metadata" do
    metadata = CrystKit::Plugins::FS.new.metadata
    policy = metadata.ipc.commands["fs.write_text"]

    policy.resources.first.capability.should eq("fs:write")
    policy.resources.first.kind.should eq(CrystKit::IPC::ResourceKind::Path)
    policy.resources.first.json_path.should eq("path")
    policy.resources.first.permission.should eq(CrystKit::IPC::ResourcePermission::Write)
  end

  it "keeps URL-scoped HTTP policy on the HTTP plugin metadata" do
    metadata = CrystKit::Plugins::HTTP.new.metadata
    policy = metadata.ipc.commands["http.get"]

    policy.resources.first.capability.should eq("http:request")
    policy.resources.first.kind.should eq(CrystKit::IPC::ResourceKind::Resource)
    policy.resources.first.json_path.should eq("url")
  end

  it "registers built-in policy only when the built-in plugin is registered" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
      app.router.policy_resolver.resolve("fs.read_text").risk.should eq(CrystKit::IPC::RiskLevel::Public)

      app.plugin(CrystKit::Plugins::FS.new)

      policy = app.router.policy_resolver.resolve("fs.read_text")
      policy.resources.first.capability.should eq("fs:read")
    end
  end

  it "allows built-ins to declare public commands in their own metadata" do
    metadata = CrystKit::Plugins::Window.new.metadata

    metadata.ipc.commands["window.list"].risk.should eq(CrystKit::IPC::RiskLevel::Public)
    metadata.ipc.commands["window.exists"].risk.should eq(CrystKit::IPC::RiskLevel::Public)
  end

  it "keeps biometric feature detection public and authentication gated" do
    metadata = CrystKit::Plugins::Biometric.new.metadata

    metadata.ipc.commands["biometric.available"].risk.should eq(CrystKit::IPC::RiskLevel::Public)
    metadata.ipc.commands["biometric.authenticate"].capability.should eq("biometric:authenticate")
  end

  it "requires every built-in command declaration to include plugin-local IPC policy" do
    missing = [] of String

    built_in_metadata_blocks.each do |file, block|
      commands = block.scan(/commands:\s*%w\(([^)]*)\)/m).flat_map do |match|
        match[1].split(/\s+/).reject(&.empty?)
      end
      next if commands.empty?

      missing << file unless block.includes?("ipc:")
    end

    missing.should eq([] of String)
  end
end

private def built_in_metadata_blocks : Array({String, String})
  root = Path[__DIR__] / ".." / "src" / "plugins" / "builtins"
  Dir.glob((root / "*.cr").to_s).map do |file|
    source = File.read(file)
    metadata_start = source.index("def metadata")
    next {File.basename(file), ""} unless metadata_start

    metadata_end = source.index("def initialize_plugin", metadata_start) || source.size
    {File.basename(file), source[metadata_start...metadata_end]}
  end
end
