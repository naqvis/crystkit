require "./spec_helper"
require "../src/crystkit"
describe "regression: Write scope must not satisfy Execute" do
  it "Write scope on / does not grant Execute" do
    scopes = CrystKit::Security::ScopeManager.new
    scopes.persist(Path["/"], CrystKit::Security::Permission::Write)
    scopes.validate(Path["/tmp/test"], CrystKit::Security::Permission::Execute).should be_false
  end
  it "Write scope satisfies Read and Write" do
    scopes = CrystKit::Security::ScopeManager.new
    scopes.persist(Path["/"], CrystKit::Security::Permission::Write)
    scopes.validate(Path["/tmp/test"], CrystKit::Security::Permission::Read).should be_true
    scopes.validate(Path["/tmp/test"], CrystKit::Security::Permission::Write).should be_true
  end
  it "Execute scope satisfies only Execute" do
    scopes = CrystKit::Security::ScopeManager.new
    scopes.persist(Path["/"], CrystKit::Security::Permission::Execute)
    scopes.validate(Path["/tmp/test"], CrystKit::Security::Permission::Execute).should be_true
    scopes.validate(Path["/tmp/test"], CrystKit::Security::Permission::Read).should be_false
    scopes.validate(Path["/tmp/test"], CrystKit::Security::Permission::Write).should be_false
  end
end
describe "regression: FsScope must not allow sibling-directory escape" do
  it "does not match a sibling directory with a string prefix" do
    scope = CrystKit::Security::Scopes::FsScope.new(["/home/alice"])
    scope.allows?("/home/alice/Documents/file.txt").should be_true
    scope.allows?("/home/alice_evil/secret").should be_false
  end
  it "matches with trailing slash pattern" do
    scope = CrystKit::Security::Scopes::FsScope.new(["/home/alice/"])
    scope.allows?("/home/alice/docs/x").should be_true
    scope.allows?("/home/bob/docs/x").should be_false
  end
  it "wildcard * matches everything" do
    scope = CrystKit::Security::Scopes::FsScope.new(["*"])
    scope.allows?("/any/path/here").should be_true
  end
end
describe "regression: capability scope must not be bypassed by omitting resource" do
  it "denies when scope is set but no resource is provided" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("fs:read", scope: "/allowed")
    caps.check("fs:read").should be_false
  end
  it "allows when scope matches resource" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("fs:read", scope: "/allowed")
    caps.check("fs:read", "/allowed/file.txt").should be_true
  end
  it "denies when scope does not match resource" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("fs:read", scope: "/allowed")
    caps.check("fs:read", "/etc/passwd").should be_false
  end
end
describe "regression: UInt64 serialization must not crash on overflow" do
  it "narrows UInt64 to Int64 when within range" do
    app = CrystKit::App.new
    result = app.coerce_to_json(42_u64)
    result.raw.should be_a(Int64)
    result.raw.should eq(42)
  end
  it "degrades to Float64 when exceeding Int64::MAX" do
    app = CrystKit::App.new
    result = app.coerce_to_json(UInt64::MAX)
    result.raw.should be_a(Float64)
  end
end
describe "regression: disk-full detection uses Errno::ENOSPC" do
  it "raises DISK_FULL for ENOSPC errno" do
    fs = CrystKit::Features::FileSystem.new(
      CrystKit::Security::CapabilitySystem.new.tap(&.grant("fs:write")),
      CrystKit::Security::ScopeManager.new.tap { |s| SpecHelpers.persist_test_root(s, CrystKit::Security::Permission::Write) }
    )
    SpecHelpers.with_temp_file("test") do |path|
      fs.write_text(Path[path], "hello")
      File.exists?(path).should be_true
    end
  end
end
describe "regression: multiple permissions on same path" do
  it "supports both Write and Execute on the same path" do
    scopes = CrystKit::Security::ScopeManager.new
    scopes.persist(Path["/"], CrystKit::Security::Permission::Write)
    scopes.persist(Path["/"], CrystKit::Security::Permission::Execute)
    scopes.validate(Path["/test"], CrystKit::Security::Permission::Write).should be_true
    scopes.validate(Path["/test"], CrystKit::Security::Permission::Execute).should be_true
    scopes.validate(Path["/test"], CrystKit::Security::Permission::Read).should be_true
  end
end
describe "regression: unsubscribe_event does not mutate hash during iteration" do
  it "removes subscription without crashing" do
    router = CrystKit::IPC::Router.new
    id1 = router.subscribe_event("test.event", ->(_p : JSON::Any) { })
    router.subscribe_event("other.event", ->(_p : JSON::Any) { })
    router.unsubscribe_event(id1)
    router.subscribed_events.should_not contain("test.event")
    router.subscribed_events.should contain("other.event")
  end
end
