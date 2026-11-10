require "./spec_helper"
require "../src/test/fake_window_backend"

describe CrystKit::Test::FakeWindowBackend do
  it "creates a window without a native webview handle" do
    services = CrystKit::Platform::Services.new(window: CrystKit::Test::FakeWindowBackend.new)
    app = CrystKit::App.new(SpecHelpers.storage_config, platform: services)
    app.command("greet", String) { |name| "Hello, #{name}" }
    win = app.window(title: "Main", label: "main", html: "<h1>Hi</h1>")
    win.label.should eq("main")
    win.native.window.null?.should be_true
    app.window_registry.find?("main").should_not be_nil
  end

  it "wires IPC commands that can be invoked through FakeFrontend" do
    services = CrystKit::Platform::Services.new(window: CrystKit::Test::FakeWindowBackend.new)
    app = CrystKit::App.new(SpecHelpers.storage_config, platform: services)
    app.command("greet", String) { |name| "Hello, #{name}" }
    app.window(title: "Main", label: "main", html: "<h1>Hi</h1>")
    frontend = CrystKit::Test::FakeFrontend.new(app)
    begin
      result = frontend.invoke("greet", JSON::Any.new("Crystal"))
      result.ok?.should be_true
      result.value.not_nil!.as_s.should eq("Hello, Crystal")
    ensure
      frontend.detach
    end
  end
end
