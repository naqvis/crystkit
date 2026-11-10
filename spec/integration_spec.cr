require "./spec_helper"
require "../src/features/system_theme"
require "../src/features/drag_source"
require "../src/features/permissions"
require "../src/features/toolbar"
require "../src/security/capability"

alias SystemThemeValue = CrystKit::Features::SystemTheme::Theme

describe CrystKit::Features::SystemTheme do
  it "returns the provider's effective theme" do
    provider = CrystKit::Test::FakeThemeProvider.new(SystemThemeValue::Dark)
    CrystKit::Features::SystemTheme.new(provider).current.should eq(SystemThemeValue::Dark)
  end

  it "delivers changes and stops its provider" do
    provider = CrystKit::Test::FakeThemeProvider.new
    theme = CrystKit::Features::SystemTheme.new(provider)
    channel = theme.start_monitor
    provider.running?.should be_true

    provider.change(SystemThemeValue::Dark)
    channel.receive.should eq("dark")

    theme.stop_monitor
    provider.running?.should be_false
    channel.closed?.should be_true
  end

  it "closes the previous stream when restarted" do
    provider = CrystKit::Test::FakeThemeProvider.new
    theme = CrystKit::Features::SystemTheme.new(provider)
    previous = theme.start_monitor
    current = theme.start_monitor

    previous.closed?.should be_true
    provider.change(SystemThemeValue::Dark)
    current.receive.should eq("dark")
  end
end

describe CrystKit::Features::DragSource do
  it "returns false without a native window" do
    ds = CrystKit::Features::DragSource.new
    ds.start_file_drag("/tmp/test.txt").should be_false
    ds.start_image_drag("/tmp/test.png").should be_false
  end

  it "enforces the drag:source capability" do
    caps = CrystKit::Security::CapabilitySystem.new
    ds = CrystKit::Features::DragSource.new(caps)
    expect_raises(CrystKit::Core::SecurityError, /drag:source/) do
      ds.start_url_drag("https://example.com")
    end
  end
end

describe CrystKit::Features::Permissions do
  it "handles a permission request via handler chain" do
    pm = CrystKit::Features::Permissions.new
    origin = URI.parse("https://example.com")
    handled = false
    pm.on_request { |req| handled = true; req.state = CrystKit::Features::PermissionState::Granted }
    state = pm.handle_request(CrystKit::Features::PermissionType::Camera, origin)
    handled.should be_true
    state.should eq(CrystKit::Features::PermissionState::Granted)
  end

  it "falls back to default when no handler responds" do
    pm = CrystKit::Features::Permissions.new
    pm.set_default(CrystKit::Features::PermissionType::Geolocation, CrystKit::Features::PermissionState::Denied)
    origin = URI.parse("https://example.com")
    state = pm.handle_request(CrystKit::Features::PermissionType::Geolocation, origin)
    state.should eq(CrystKit::Features::PermissionState::Denied)
  end

  it "persists and retrieves permission state via storage" do
    SpecHelpers.with_temp_dir do |dir|
      storage = Path[dir] / ".crystkit" / "permissions"
      pm = CrystKit::Features::Permissions.new(storage)
      origin = URI.parse("https://example.com")
      pm.persist(origin, CrystKit::Features::PermissionType::Microphone, CrystKit::Features::PermissionState::Granted)
      retrieved = pm.persisted_state(origin, CrystKit::Features::PermissionType::Microphone)
      retrieved.should eq(CrystKit::Features::PermissionState::Granted)
    end
  end

  it "respects per-origin persisted state over defaults" do
    SpecHelpers.with_temp_dir do |dir|
      storage = Path[dir] / ".crystkit" / "permissions"
      pm = CrystKit::Features::Permissions.new(storage)
      origin = URI.parse("https://example.com")
      pm.set_default(CrystKit::Features::PermissionType::Camera, CrystKit::Features::PermissionState::Prompt)
      pm.persist(origin, CrystKit::Features::PermissionType::Camera, CrystKit::Features::PermissionState::Denied)
      state = pm.handle_request(CrystKit::Features::PermissionType::Camera, origin)
      state.should eq(CrystKit::Features::PermissionState::Denied)
    end
  end

  it "resets defaults via set_default" do
    pm = CrystKit::Features::Permissions.new
    pm.set_default(CrystKit::Features::PermissionType::Camera, CrystKit::Features::PermissionState::Denied)
    pm.set_default(CrystKit::Features::PermissionType::Microphone, CrystKit::Features::PermissionState::Denied)
    pm.set_default(CrystKit::Features::PermissionType::Geolocation, CrystKit::Features::PermissionState::Denied)
    pm.set_default(CrystKit::Features::PermissionType::Camera, CrystKit::Features::PermissionState::Prompt)
    pm.set_default(CrystKit::Features::PermissionType::Microphone, CrystKit::Features::PermissionState::Prompt)
    pm.set_default(CrystKit::Features::PermissionType::Geolocation, CrystKit::Features::PermissionState::Prompt)
    pm.default(CrystKit::Features::PermissionType::Camera).should eq(CrystKit::Features::PermissionState::Prompt)
    pm.default(CrystKit::Features::PermissionType::Microphone).should eq(CrystKit::Features::PermissionState::Prompt)
    pm.default(CrystKit::Features::PermissionType::Geolocation).should eq(CrystKit::Features::PermissionState::Prompt)
  end
end

describe CrystKit::Features::Toolbar do
  it "adds items with actions" do
    backend = CrystKit::Test::FakeToolbarProvider.new
    tb = CrystKit::Features::Toolbar.new(nil, backend)
    triggered = false
    tb.add_item("save", "Save") { triggered = true }
    tb.items.size.should eq(1)
    tb.items.first.id.should eq("save")
    tb.items.first.action.try(&.call)
    triggered.should be_true
  end

  it "removes items by id" do
    backend = CrystKit::Test::FakeToolbarProvider.new
    tb = CrystKit::Features::Toolbar.new(nil, backend)
    tb.add_item("a", "A") { }
    tb.add_item("b", "B") { }
    tb.remove_item("a")
    tb.items.size.should eq(1)
    tb.items.first.id.should eq("b")
  end

  it "clears all items" do
    backend = CrystKit::Test::FakeToolbarProvider.new
    tb = CrystKit::Features::Toolbar.new(nil, backend)
    tb.add_item("x", "X") { }
    tb.add_item("y", "Y") { }
    tb.clear
    tb.items.should be_empty
  end

  it "toggles visibility through the model flag" do
    backend = CrystKit::Test::FakeToolbarProvider.new
    tb = CrystKit::Features::Toolbar.new(nil, backend)
    tb.hide
    tb.visible?.should be_false
    tb.show
    tb.visible?.should be_true
  end

  it "pushes item changes to the backend on sync" do
    backend = CrystKit::Test::FakeToolbarProvider.new
    tb = CrystKit::Features::Toolbar.new(nil, backend)
    tb.add_item("x", "X") { }
    tb.sync
    backend.items.size.should eq(1)
    backend.items.first.id.should eq("x")
  end

  it "adds separator items" do
    backend = CrystKit::Test::FakeToolbarProvider.new
    tb = CrystKit::Features::Toolbar.new(nil, backend)
    tb.add_separator
    tb.items.size.should eq(1)
    tb.items.first.id.should eq("__separator__")
  end
end
