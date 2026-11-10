require "./spec_helper"
require "../src/state/registry"
require "../src/app/app"
require "../src/ipc/js_bridge"

private class TestSettingsState
  include JSON::Serializable

  property theme : String
  property sidebar_width : Int32
  property? notifications : Bool

  def initialize(@theme : String, @sidebar_width : Int32, @notifications : Bool)
  end
end

private class TestNestedState
  include JSON::Serializable

  property settings : TestSettingsState
  property tags : Array(String)

  def initialize(@settings : TestSettingsState, @tags : Array(String))
  end
end

describe CrystKit::State::Slice do
  it "captures ordinary Crystal property mutations as JSON Patch" do
    changes = [] of CrystKit::State::Change
    slice = CrystKit::State::Slice(TestSettingsState).new(
      "settings",
      TestSettingsState.new("light", 240, true),
      ->(change : CrystKit::State::Change) { changes << change },
    )

    slice.update do |settings|
      settings.theme = "dark"
      settings.sidebar_width = 280
      settings
    end

    changes.size.should eq(1)
    patch = changes.first.patch
    patch.map(&.["path"].as_s).should eq(["/theme", "/sidebar_width"])
    slice.value.theme.should eq("dark")
    slice.value.sidebar_width.should eq(280)
  end

  it "captures nested object and array mutations" do
    changes = [] of CrystKit::State::Change
    slice = CrystKit::State::Slice(TestNestedState).new(
      "ui",
      TestNestedState.new(TestSettingsState.new("light", 240, true), ["one"]),
      ->(change : CrystKit::State::Change) { changes << change },
    )

    slice.update do |state|
      state.settings.theme = "dark"
      state.tags << "two"
      state
    end

    patch = changes.first.patch
    patch.map(&.["path"].as_s).should eq(["/settings/theme", "/tags/1"])
    patch.to_a[1]["op"].as_s.should eq("add")
  end

  it "does not emit an empty patch for no-op updates" do
    changes = [] of CrystKit::State::Change
    slice = CrystKit::State::Slice(TestSettingsState).new(
      "settings",
      TestSettingsState.new("light", 240, true),
      ->(change : CrystKit::State::Change) { changes << change },
    )

    slice.update { |settings| settings }

    changes.should be_empty
  end
end

describe CrystKit::State::Registry do
  it "rejects duplicate state names" do
    registry = CrystKit::State::Registry.new(->(_change : CrystKit::State::Change) { })
    registry.register("settings", TestSettingsState.new("light", 240, true))

    expect_raises(CrystKit::Core::ValidationError, /already registered/) do
      registry.register("settings", TestSettingsState.new("dark", 280, false))
    end
  end

  it "fetches typed slices by name" do
    registry = CrystKit::State::Registry.new(->(_change : CrystKit::State::Change) { })
    registered = registry.register("settings", TestSettingsState.new("light", 240, true))

    registry.fetch("settings", TestSettingsState).should be(registered)
    registry.fetch?("settings", TestSettingsState).should be(registered)
    registry.fetch?("settings", TestNestedState).should be_nil
  end

  it "raises when fetching a slice with the wrong type" do
    registry = CrystKit::State::Registry.new(->(_change : CrystKit::State::Change) { })
    registry.register("settings", TestSettingsState.new("light", 240, true))

    expect_raises(CrystKit::Core::ValidationError, /not a TestNestedState/) do
      registry.fetch("settings", TestNestedState)
    end
  end
end

describe CrystKit::App, "#state" do
  it "registers a frontend-reactive state slice and exposes attach over private IPC" do
    app = CrystKit::App.new
    app.state("settings", TestSettingsState) { TestSettingsState.new("light", 240, true) }

    result = app.router.invoke_command("__crystkit.state.attach", JSON::Any.new("settings"))

    result["name"].as_s.should eq("settings")
    result["value"]["theme"].as_s.should eq("light")
    result["value"]["sidebar_width"].as_i.should eq(240)
  end

  it "looks up existing typed state slices" do
    app = CrystKit::App.new
    registered = app.state("settings", TestSettingsState) { TestSettingsState.new("light", 240, true) }

    app.state("settings", TestSettingsState).should be(registered)
    app.state?("settings", TestSettingsState).should be(registered)
    app.state?("settings", TestNestedState).should be_nil
  end

  it "emits private state patch events when a registered slice changes" do
    app = CrystKit::App.new
    payloads = [] of JSON::Any
    app.router.subscribe_event("__crystkit.state.patch", ->(payload : JSON::Any) { payloads << payload })
    settings = app.state("settings", TestSettingsState) { TestSettingsState.new("light", 240, true) }

    settings.update do |state|
      state.notifications = false
      state
    end

    payloads.size.should eq(1)
    payloads.first["name"].as_s.should eq("settings")
    payloads.first["patch"].as_a.first["path"].as_s.should eq("/notifications")
    payloads.first["patch"].as_a.first["value"].as_bool.should be_false
  end

  it "returns a structured error for unknown state attach requests" do
    app = CrystKit::App.new

    envelope = app.router.invoke_envelope("__crystkit.state.attach", JSON::Any.new("missing"))

    envelope.ok?.should be_false
    envelope.error.not_nil!.code.should eq("STATE_NOT_FOUND")
  end
end

describe "CrystKit frontend state bridge" do
  it "exposes a state helper and private state patch listener" do
    CrystKit::IPC::IPC_JS_CLIENT.should contain("state: function(name)")
    CrystKit::IPC::IPC_JS_CLIENT.should contain("__crystkit.state.attach")
    CrystKit::IPC::IPC_JS_CLIENT.should contain("__crystkit.state.patch")
    CrystKit::IPC::IPC_JS_CLIENT.should contain("applyPatch")
    CrystKit::IPC::IPC_JS_CLIENT.should contain("get value()")
    CrystKit::IPC::IPC_JS_CLIENT.should contain("subscribe: function(handler)")
  end
end
