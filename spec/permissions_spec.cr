require "./spec_helper"
require "../src/features/permissions"

describe CrystKit::Features::PermissionType do
  it "parses from string" do
    ptype = CrystKit::Features::PermissionType.parse?("Camera")
    ptype.should eq(CrystKit::Features::PermissionType::Camera)
  end
end

describe CrystKit::Features::Permissions do
  it "defaults all types to Prompt" do
    perms = CrystKit::Features::Permissions.new
    perms.default(CrystKit::Features::PermissionType::Camera).should eq(CrystKit::Features::PermissionState::Prompt)
    perms.default(CrystKit::Features::PermissionType::Geolocation).should eq(CrystKit::Features::PermissionState::Prompt)
  end

  it "sets defaults via grant" do
    perms = CrystKit::Features::Permissions.new
    perms.grant(CrystKit::Features::PermissionType::Camera)
    perms.default(CrystKit::Features::PermissionType::Camera).should eq(CrystKit::Features::PermissionState::Granted)
  end

  it "sets defaults via deny" do
    perms = CrystKit::Features::Permissions.new
    perms.deny(CrystKit::Features::PermissionType::Geolocation)
    perms.default(CrystKit::Features::PermissionType::Geolocation).should eq(CrystKit::Features::PermissionState::Denied)
  end

  it "sets defaults via set_default" do
    perms = CrystKit::Features::Permissions.new
    perms.set_default(CrystKit::Features::PermissionType::Notifications, CrystKit::Features::PermissionState::Denied)
    perms.default(CrystKit::Features::PermissionType::Notifications).should eq(CrystKit::Features::PermissionState::Denied)
  end

  it "returns default when no handler modifies request" do
    perms = CrystKit::Features::Permissions.new
    perms.grant(CrystKit::Features::PermissionType::Camera)

    result = perms.handle_request(
      CrystKit::Features::PermissionType::Camera,
      URI.parse("https://example.com"),
    )
    result.should eq(CrystKit::Features::PermissionState::Granted)
  end

  it "passes request through registered handler" do
    perms = CrystKit::Features::Permissions.new
    handler_called = false

    perms.on_request do |req|
      handler_called = true
      req.state = CrystKit::Features::PermissionState::Granted
    end

    result = perms.handle_request(
      CrystKit::Features::PermissionType::Geolocation,
      URI.parse("https://example.com"),
    )
    handler_called.should be_true
    result.should eq(CrystKit::Features::PermissionState::Granted)
  end

  it "handler can deny a request" do
    perms = CrystKit::Features::Permissions.new
    perms.grant(CrystKit::Features::PermissionType::Camera)

    perms.on_request do |req|
      req.state = CrystKit::Features::PermissionState::Denied
    end

    result = perms.handle_request(
      CrystKit::Features::PermissionType::Camera,
      URI.parse("https://example.com"),
    )
    result.should eq(CrystKit::Features::PermissionState::Denied)
  end

  it "handler decision overrides default" do
    perms = CrystKit::Features::Permissions.new
    perms.deny(CrystKit::Features::PermissionType::Camera)

    perms.on_request do |req|
      req.state = CrystKit::Features::PermissionState::Granted
    end

    result = perms.handle_request(
      CrystKit::Features::PermissionType::Camera,
      URI.parse("https://example.com"),
    )
    result.should eq(CrystKit::Features::PermissionState::Granted)
  end

  it "runs multiple handlers" do
    perms = CrystKit::Features::Permissions.new
    calls = [] of String

    perms.on_request { |_| calls << "first" }
    perms.on_request { |req| calls << "second"; req.state = CrystKit::Features::PermissionState::Denied }

    perms.handle_request(
      CrystKit::Features::PermissionType::Camera,
      URI.parse("https://example.com"),
    )
    calls.should eq(["first", "second"])
  end

  it "persists and retrieves state" do
    SpecHelpers.with_temp_dir do |dir|
      storage = Path[dir] / "perms"
      perms = CrystKit::Features::Permissions.new(storage)

      origin = URI.parse("https://example.com")
      perms.persist(origin, CrystKit::Features::PermissionType::Camera, CrystKit::Features::PermissionState::Granted)

      state = perms.persisted_state(origin, CrystKit::Features::PermissionType::Camera)
      state.should eq(CrystKit::Features::PermissionState::Granted)
    end
  end

  it "persisted state overrides default" do
    SpecHelpers.with_temp_dir do |dir|
      storage = Path[dir] / "perms"
      perms = CrystKit::Features::Permissions.new(storage)

      perms.deny(CrystKit::Features::PermissionType::Geolocation)
      origin = URI.parse("https://example.com")
      perms.persist(origin, CrystKit::Features::PermissionType::Geolocation, CrystKit::Features::PermissionState::Granted)

      result = perms.handle_request(
        CrystKit::Features::PermissionType::Geolocation,
        origin,
      )
      result.should eq(CrystKit::Features::PermissionState::Granted)
    end
  end

  it "loads persisted state on init" do
    SpecHelpers.with_temp_dir do |dir|
      storage = Path[dir] / "perms"
      perms1 = CrystKit::Features::Permissions.new(storage)
      origin = URI.parse("https://example.com")
      perms1.persist(origin, CrystKit::Features::PermissionType::Notifications, CrystKit::Features::PermissionState::Denied)

      perms2 = CrystKit::Features::Permissions.new(storage)
      state = perms2.persisted_state(origin, CrystKit::Features::PermissionType::Notifications)
      state.should eq(CrystKit::Features::PermissionState::Denied)
    end
  end
end
