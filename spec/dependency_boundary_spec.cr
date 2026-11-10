require "spec"

describe "runtime dependency boundary" do
  it "matches the rearchitecture source boundaries" do
    required_paths = %w[
      core/runtime.cr
      core/window.cr
      core/window_registry.cr
      core/lifecycle.cr
      core/errors.cr
      ipc/router.cr
      ipc/command.cr
      ipc/event.cr
      ipc/codec.cr
      ipc/schema.cr
      ipc/js_bridge.cr
      security/manifest.cr
      security/capability.cr
      security/scope.cr
      security/permission_prompt.cr
      plugins/base.cr
      plugins/registry.cr
      platform/interface.cr
      app/app.cr
      app/app_config.cr
      builder/config.cr
      features/dev_server.cr
    ]

    required_paths.each do |path|
      File.exists?(Path[__DIR__] / "../src" / path).should be_true
    end

    obsolete_paths = %w[
      app.cr
      app_config.cr
      window_manager.cr
      window_factory.cr
      plugin
      ipc/core.cr
      ipc/js_client.cr
      platform/base.cr
      cli/build.cr
      cli/config.cr
      cli/bundle
      build/config.cr
      build/dev_server.cr
      utils/errors.cr
    ]

    obsolete_paths.each do |path|
      File.exists?(Path[__DIR__] / "../src" / path).should be_false
    end
  end

  it "keeps App independent from CLI and builder configuration" do
    source = File.read(Path[__DIR__] / "../src/app/app.cr")

    source.should_not contain("require \"../cli/")
    source.should_not contain("require \"../builder/")
    source.should_not contain("require \"../build/")
    source.should_not contain("Builder::Config")
  end

  it "has no competing IPC or plugin owner implementations" do
    source = File.read(Path[__DIR__] / "../src/plugins/base.cr")

    source.should_not contain("CommandRegistry")
    source.should_not contain("EventBus")
    File.exists?(Path[__DIR__] / "../src/ipc/core.cr").should be_false
    File.exists?(Path[__DIR__] / "../src/plugin/manager.cr").should be_false
  end

  it "has no permissive security compatibility adapters" do
    source = File.read(Path[__DIR__] / "../src/security/context.cr")

    source.should_not contain("trusted_legacy")
    source.should_not contain("Compatibility adapter")
  end

  it "exposes one plugin command API without request wrappers" do
    source = File.read(Path[__DIR__] / "../src/plugins/base.cr")

    source.should_not contain("command" + "_request")
    source.should_not contain("NamedTuple")
    source.should_not contain("params.as_h.values")
  end

  it "exposes one application command API without request wrappers" do
    source = File.read(Path[__DIR__] / "../src/app/app.cr")

    source.should_not contain("command" + "_request")
    source.should_not contain("NamedTuple")
    source.should_not contain("macro command(")
    source.should_not contain("params.as_h.values")
  end

  it "has no parallel global command registration DSL" do
    source = File.read(Path[__DIR__] / "../src/crystkit.cr")

    source.should_not contain("TypedBinding")
    source.should_not contain("macro command(")
    source.should_not contain("macro register_commands")
    source.should_not contain("annotation Command")
  end

  it "uses metadata as the sole plugin dependency contract" do
    source = File.read(Path[__DIR__] / "../src/plugins/base.cr")

    source.should_not contain("def dependencies")
  end

  it "keeps cross-platform plugins independent from concrete OS modules" do
    plugin_dir = Path[__DIR__] / "../src/plugins/builtins"
    sources = Dir.glob((plugin_dir / "*.cr").to_s)
      .reject(&.ends_with?("/nspanel.cr"))
      .map { |path| File.read(path) }
      .join("\n")

    sources.should_not contain("Platform::MacOS")
    sources.should_not contain("Platform::Linux")
    sources.should_not contain("Platform::Windows")
    sources.should_not contain("{% if flag?")
    sources.should_not contain("{% elsif flag?")
  end
end
