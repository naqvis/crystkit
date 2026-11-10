require "./spec_helper"
require "../src/test/fake_frontend"

private class FakeFrontTestSettings
  include JSON::Serializable
  property theme : String
  property count : Int32

  def initialize(@theme : String, @count : Int32); end
end

describe CrystKit::Test::FakeFrontend do
  it "invokes a sync command and returns a success envelope" do
    app = CrystKit::App.new(SpecHelpers.storage_config)
    app.command("greet", String) { |name| "Hello, #{name}" }
    frontend = CrystKit::Test::FakeFrontend.new(app)
    begin
      result = frontend.invoke("greet", JSON::Any.new("Crystal"))
      result.ok?.should be_true
      result.value.not_nil!.as_s.should eq("Hello, Crystal")
    ensure
      frontend.detach
    end
  end

  it "returns a failure envelope for an unknown command" do
    app = CrystKit::App.new(SpecHelpers.storage_config)
    frontend = CrystKit::Test::FakeFrontend.new(app)
    begin
      result = frontend.invoke("nope", JSON::Any.new(nil))
      result.ok?.should be_false
      result.error.not_nil!.code.should eq("COMMAND_NOT_FOUND")
    ensure
      frontend.detach
    end
  end

  it "captures backend events bridged to the frontend" do
    app = CrystKit::App.new(SpecHelpers.storage_config)
    frontend = CrystKit::Test::FakeFrontend.new(app)
    begin
      app.emit("server:tick", JSON.parse(%({"msg":"hello"})))
      frontend.emitted?("server:tick").should be_true
      frontend.emitted_events("server:tick").first["msg"].as_s.should eq("hello")
    ensure
      frontend.detach
    end
  end

  it "supports listen subscriptions that receive router-emitted events" do
    router = CrystKit::IPC::Router.new
    frontend = CrystKit::Test::FakeFrontend.new(router)
    begin
      received = [] of JSON::Any
      unsub = frontend.listen("ping") { |p| received << p }
      router.emit_event("ping", JSON.parse(%({"v":1})))
      received.size.should eq(1)
      received.first["v"].as_i.should eq(1)
      unsub.call
      router.emit_event("ping", JSON.parse(%({"v":2})))
      received.size.should eq(1)
    ensure
      frontend.detach
    end
  end

  it "emits a declared frontend event through the router" do
    router = CrystKit::IPC::Router.new
    router.declare_frontend_event("frontend.ready")
    frontend = CrystKit::Test::FakeFrontend.new(router)
    begin
      received = [] of JSON::Any
      router.subscribe_event("frontend.ready", ->(p : JSON::Any) { received << p })
      envelope = frontend.emit("frontend.ready", JSON.parse(%({"loaded":true})))
      envelope.ok?.should be_true
      received.size.should eq(1)
      received.first["loaded"].as_bool.should be_true
    ensure
      frontend.detach
    end
  end

  it "returns a failure envelope when emitting an undeclared event" do
    router = CrystKit::IPC::Router.new
    frontend = CrystKit::Test::FakeFrontend.new(router)
    begin
      envelope = frontend.emit("not.declared", JSON::Any.new(nil))
      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("IPC_POLICY_MISSING")
    ensure
      frontend.detach
    end
  end

  it "captures channel data, close, and error events" do
    router = CrystKit::IPC::Router.new
    frontend = CrystKit::Test::FakeFrontend.new(router)
    begin
      channel = frontend.channel("test-chan-id")
      router.emit_event("__channel_data:test-chan-id", JSON.parse(%({"value":"first"})))
      router.emit_event("__channel_data:test-chan-id", JSON.parse(%({"value":"second"})))
      router.emit_event("__channel_close:test-chan-id", JSON.parse(%({})))

      channel.data.map(&.as_s).should eq(["first", "second"])
      channel.ended?.should be_true
      channel.errored?.should be_false
    ensure
      frontend.detach
    end
  end

  it "captures channel error events" do
    router = CrystKit::IPC::Router.new
    frontend = CrystKit::Test::FakeFrontend.new(router)
    begin
      channel = frontend.channel("err-chan")
      router.emit_event("__channel_error:err-chan", JSON.parse(%({"error":"boom"})))
      channel.errored?.should be_true
      channel.error_message.should eq("boom")
    ensure
      frontend.detach
    end
  end

  it "attaches to a state slice and mirrors patches" do
    app = CrystKit::App.new(SpecHelpers.storage_config)
    settings = app.state("settings", FakeFrontTestSettings) { FakeFrontTestSettings.new("light", 0) }
    frontend = CrystKit::Test::FakeFrontend.new(app)
    begin
      ref = frontend.state("settings")
      ref.name.should eq("settings")
      ref.value["theme"].as_s.should eq("light")
      ref.value["count"].as_i.should eq(0)

      notified = [] of JSON::Any
      ref.subscribe { |v| notified << v }

      settings.update do |s|
        s.theme = "dark"
        s.count = 5
        s
      end

      ref.value["theme"].as_s.should eq("dark")
      ref.value["count"].as_i.should eq(5)
      notified.size.should eq(1)
      notified.first["theme"].as_s.should eq("dark")

      frontend.state_patches.size.should be >= 1
      ref.patches.size.should eq(1)
    ensure
      frontend.detach
    end
  end

  it "raises when attaching to an unknown state slice" do
    app = CrystKit::App.new(SpecHelpers.storage_config)
    frontend = CrystKit::Test::FakeFrontend.new(app)
    begin
      expect_raises(CrystKit::Core::IPCError, /not registered/) do
        frontend.state("missing")
      end
    ensure
      frontend.detach
    end
  end

  it "clear resets captured events and state patches" do
    app = CrystKit::App.new(SpecHelpers.storage_config)
    frontend = CrystKit::Test::FakeFrontend.new(app)
    begin
      app.emit("ev.one", JSON::Any.new(nil))
      app.emit("ev.two", JSON::Any.new(nil))
      frontend.emitted.size.should eq(2)

      frontend.clear
      frontend.emitted.should be_empty
      frontend.state_patches.should be_empty
    ensure
      frontend.detach
    end
  end

  it "detach removes capture hooks so no further events are recorded" do
    app = CrystKit::App.new(SpecHelpers.storage_config)
    frontend = CrystKit::Test::FakeFrontend.new(app)
    frontend.detach

    app.emit("after.detach", JSON::Any.new(nil))
    frontend.emitted.should be_empty
  end

  it "works with a standalone router (no app)" do
    router = CrystKit::IPC::Router.new
    router.command("ping") { JSON::Any.new("pong") }
    frontend = CrystKit::Test::FakeFrontend.new(router)
    begin
      result = frontend.invoke("ping", JSON::Any.new(nil))
      result.ok?.should be_true
      result.value.not_nil!.as_s.should eq("pong")
    ensure
      frontend.detach
    end
  end
end
