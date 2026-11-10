require "./spec_helper"
require "../src/security/capability"
require "../src/security/scope"
require "../src/app/app"
describe CrystKit::Security::CapabilitySystem do
  describe "#grant and #check" do
    it "grants and checks a capability" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("fs:read")
      caps.check("fs:read").should be_true
    end
    it "returns false for ungranated capability" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.check("fs:write").should be_false
    end
    it "returns false for expired capability" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("temp:cap", expires_at: Time.utc - 1.second)
      caps.check("temp:cap").should be_false
    end
  end
  describe "#revoke" do
    it "revokes a granted capability" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("http:request")
      caps.revoke("http:request")
      caps.check("http:request").should be_false
    end
  end
  describe "#query" do
    it "returns all non-expired capabilities" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("a")
      caps.grant("b")
      caps.grant("expired", expires_at: Time.utc - 1.second)
      names = caps.query.map(&.name)
      names.should contain("a")
      names.should contain("b")
      names.should_not contain("expired")
    end
  end
  describe "#require!" do
    it "does not raise when capability is granted" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("ok:cap")
      caps.require!("ok:cap")
    end
    it "raises SecurityError when capability is missing" do
      caps = CrystKit::Security::CapabilitySystem.new
      expect_raises(CrystKit::Core::SecurityError, /Missing capability: missing:cap/) do
        caps.require!("missing:cap")
      end
    end
    it "logs a violation when capability is missing" do
      caps = CrystKit::Security::CapabilitySystem.new
      begin
        caps.require!("denied:cap", resource: "/secret", context: "test")
      rescue CrystKit::Core::SecurityError
      end
      caps.violations.size.should eq(1)
      caps.violations[0].capability.should eq("denied:cap")
      caps.violations[0].resource.should eq("/secret")
    end
  end
  describe "#check_for_window" do
    it "returns true when window has the capability" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant_to_window("fs:read", "main")
      caps.check_for_window("fs:read", "main").should be_true
    end
    it "returns false when window does not have the capability" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("fs:read")
      caps.check_for_window("fs:read", "settings").should be_false
    end
    it "returns false when the global capability is not granted" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant_to_window("fs:read", "main")
      caps.revoke("fs:read")
      caps.check_for_window("fs:read", "main").should be_false
    end
  end
  describe "#require_for_window!" do
    it "does not raise when window has the capability" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant_to_window("fs:read", "main")
      caps.require_for_window!("fs:read", "main")
    end
    it "raises SecurityError when window does not have the capability" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("fs:read")
      expect_raises(CrystKit::Core::SecurityError, /Missing capability: fs:read for window 'settings'/) do
        caps.require_for_window!("fs:read", "settings")
      end
    end
    it "logs a violation when window capability is missing" do
      caps = CrystKit::Security::CapabilitySystem.new
      begin
        caps.require_for_window!("fs:write", "child", context: "test-context")
      rescue CrystKit::Core::SecurityError
      end
      caps.violations.size.should eq(1)
      caps.violations[0].capability.should eq("fs:write")
    end
    it "includes resource in the error message when provided" do
      caps = CrystKit::Security::CapabilitySystem.new
      expect_raises(CrystKit::Core::SecurityError, /and resource \/home\/user/) do
        caps.require_for_window!("fs:read", "main", resource: "/home/user/file.txt")
      end
    end
  end
  describe "#window_capabilities" do
    it "returns capabilities explicitly granted to a window" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant_to_window("fs:read", "main")
      caps.grant_to_window("http:request", "main")
      caps.window_capabilities("main").sort.should eq(["fs:read", "http:request"])
    end
    it "returns empty array for a window with no capabilities" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.window_capabilities("unknown").should be_empty
    end
  end
  describe "#revoke_from_window" do
    it "removes a capability from a window" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant_to_window("fs:read", "main")
      caps.revoke_from_window("fs:read", "main")
      caps.check_for_window("fs:read", "main").should be_false
    end
    it "is a no-op for a window that does not have the capability" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant_to_window("fs:read", "main")
      caps.revoke_from_window("http:request", "main")
      caps.window_capabilities("main").should eq(["fs:read"])
    end
    it "is a no-op for an unknown window" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.revoke_from_window("fs:read", "nonexistent")
    end
  end
  describe "capability inheritance" do
    describe "#set_window_parent" do
      it "allows child window to inherit parent capabilities" do
        caps = CrystKit::Security::CapabilitySystem.new
        caps.grant_to_window("fs:read", "parent")
        caps.set_window_parent("child", "parent")
        caps.check_for_window("fs:read", "child").should be_true
      end
      it "child does not inherit capabilities the parent does not have" do
        caps = CrystKit::Security::CapabilitySystem.new
        caps.grant_to_window("fs:read", "parent")
        caps.set_window_parent("child", "parent")
        caps.check_for_window("http:request", "child").should be_false
      end
      it "supports multi-level inheritance (grandchild inherits from grandparent)" do
        caps = CrystKit::Security::CapabilitySystem.new
        caps.grant_to_window("fs:read", "grandparent")
        caps.set_window_parent("parent", "grandparent")
        caps.set_window_parent("child", "parent")
        caps.check_for_window("fs:read", "child").should be_true
      end
      it "child's own capabilities are also effective" do
        caps = CrystKit::Security::CapabilitySystem.new
        caps.grant_to_window("fs:read", "parent")
        caps.grant_to_window("http:request", "child")
        caps.set_window_parent("child", "parent")
        caps.check_for_window("fs:read", "child").should be_true
        caps.check_for_window("http:request", "child").should be_true
      end
      it "raises ArgumentError when a window is set as its own parent" do
        caps = CrystKit::Security::CapabilitySystem.new
        expect_raises(ArgumentError, /own parent/) do
          caps.set_window_parent("win", "win")
        end
      end
      it "raises ArgumentError when setting parent would create a cycle" do
        caps = CrystKit::Security::CapabilitySystem.new
        caps.set_window_parent("b", "a")
        expect_raises(ArgumentError, /cycle/) do
          caps.set_window_parent("a", "b")
        end
      end
      it "raises ArgumentError for longer cycles" do
        caps = CrystKit::Security::CapabilitySystem.new
        caps.set_window_parent("b", "a")
        caps.set_window_parent("c", "b")
        expect_raises(ArgumentError, /cycle/) do
          caps.set_window_parent("a", "c")
        end
      end
    end
    describe "#unset_window_parent" do
      it "stops capability inheritance after unsetting parent" do
        caps = CrystKit::Security::CapabilitySystem.new
        caps.grant_to_window("fs:read", "parent")
        caps.set_window_parent("child", "parent")
        caps.check_for_window("fs:read", "child").should be_true
        caps.unset_window_parent("child")
        caps.check_for_window("fs:read", "child").should be_false
      end
    end
    describe "#window_parent" do
      it "returns the parent window ID" do
        caps = CrystKit::Security::CapabilitySystem.new
        caps.set_window_parent("child", "parent")
        caps.window_parent("child").should eq("parent")
      end
      it "returns nil when no parent is set" do
        caps = CrystKit::Security::CapabilitySystem.new
        caps.window_parent("orphan").should be_nil
      end
    end
    describe "#effective_capabilities_for_window" do
      it "returns own capabilities when no parent" do
        caps = CrystKit::Security::CapabilitySystem.new
        caps.grant_to_window("fs:read", "win")
        caps.effective_capabilities_for_window("win").should contain("fs:read")
      end
      it "returns merged capabilities from entire ancestor chain" do
        caps = CrystKit::Security::CapabilitySystem.new
        caps.grant_to_window("fs:read", "grandparent")
        caps.grant_to_window("http:request", "parent")
        caps.grant_to_window("shell:execute", "child")
        caps.set_window_parent("parent", "grandparent")
        caps.set_window_parent("child", "parent")
        effective = caps.effective_capabilities_for_window("child")
        effective.should contain("fs:read")
        effective.should contain("http:request")
        effective.should contain("shell:execute")
      end
      it "returns empty array for a window with no capabilities and no parent" do
        caps = CrystKit::Security::CapabilitySystem.new
        caps.effective_capabilities_for_window("unknown").should be_empty
      end
    end
  end
  describe "#load_manifest" do
    it "loads capabilities from a JSON manifest file" do
      manifest_json = %({"capabilities":["fs:read","http:request"],"windows":{"main":["fs:read"]}})
      SpecHelpers.with_temp_file(manifest_json) do |path|
        caps = CrystKit::Security::CapabilitySystem.new
        caps.load_manifest(Path[path])
        caps.check("fs:read").should be_true
        caps.check("http:request").should be_true
        caps.check_for_window("fs:read", "main").should be_true
      end
    end
    it "raises when manifest file does not exist" do
      caps = CrystKit::Security::CapabilitySystem.new
      expect_raises(CrystKit::Core::SecurityError, /not found/) do
        caps.load_manifest(Path["/nonexistent/manifest.json"])
      end
    end
  end
  describe "#audit_log" do
    it "records violations" do
      caps = CrystKit::Security::CapabilitySystem.new
      violation = CrystKit::Security::CapabilityViolation.new("shell:execute", "/bin/sh", "test context")
      caps.audit_log(violation)
      caps.violations.size.should eq(1)
      caps.violations[0].capability.should eq("shell:execute")
    end
  end
  describe "manifest format validation" do
    describe "Manifest.validate" do
      it "returns empty array for a valid minimal manifest" do
        errors = CrystKit::Security::Manifest.validate("{}")
        errors.should be_empty
      end
      it "returns empty array for a fully populated valid manifest" do
        json = %({"capabilities":["fs:read","http:request"],"groups":{"net":["http:request"]},"windows":{"main":["fs:read"]},"scopes":{"fs":["/tmp/*"]}})
        errors = CrystKit::Security::Manifest.validate(json)
        errors.should be_empty
      end
      it "returns an error for invalid JSON" do
        errors = CrystKit::Security::Manifest.validate("not json")
        errors.size.should eq(1)
        errors[0].should contain("Invalid JSON")
      end
      it "returns an error when root is not an object" do
        errors = CrystKit::Security::Manifest.validate("[1,2,3]")
        errors.size.should eq(1)
        errors[0].should contain("Invalid manifest structure")
      end
      it "returns an error when capabilities has a wrong type" do
        errors = CrystKit::Security::Manifest.validate(%({"capabilities":"bad"}))
        errors.size.should eq(1)
        errors[0].should contain("Invalid manifest structure")
      end
      it "returns an error for a non-string capability entry" do
        errors = CrystKit::Security::Manifest.validate(%({"capabilities":[1]}))
        errors.size.should eq(1)
        errors[0].should contain("Invalid manifest structure")
      end
      it "returns an error for an empty capability name" do
        errors = CrystKit::Security::Manifest.validate(%({"capabilities":[""]}))
        errors.any?(&.includes?("must not be empty")).should be_true
      end
      it "returns an error for a capability name with invalid characters" do
        errors = CrystKit::Security::Manifest.validate(%({"capabilities":["bad cap!"]}))
        errors.any?(&.includes?("invalid characters")).should be_true
      end
      it "returns an error when groups has a wrong type" do
        errors = CrystKit::Security::Manifest.validate(%({"groups":"bad"}))
        errors.size.should eq(1)
        errors[0].should contain("Invalid manifest structure")
      end
      it "returns an error when a group value is not an array" do
        errors = CrystKit::Security::Manifest.validate(%({"groups":{"g1":"bad"}}))
        errors.size.should eq(1)
        errors[0].should contain("Invalid manifest structure")
      end
      it "returns an error when windows has a wrong type" do
        errors = CrystKit::Security::Manifest.validate(%({"windows":42}))
        errors.size.should eq(1)
        errors[0].should contain("Invalid manifest structure")
      end
      it "returns an error when scopes has a wrong type" do
        errors = CrystKit::Security::Manifest.validate(%({"scopes":"bad"}))
        errors.size.should eq(1)
        errors[0].should contain("Invalid manifest structure")
      end
    end
    describe "#load_manifest with invalid format" do
      it "raises ValidationError when manifest has format errors" do
        SpecHelpers.with_temp_file(%({"capabilities":"not-an-array"})) do |path|
          caps = CrystKit::Security::CapabilitySystem.new
          expect_raises(CrystKit::Core::ValidationError, /manifest format errors/) do
            caps.load_manifest(Path[path])
          end
        end
      end
      it "raises ValidationError for invalid JSON in manifest file" do
        SpecHelpers.with_temp_file("not valid json") do |path|
          caps = CrystKit::Security::CapabilitySystem.new
          expect_raises(CrystKit::Core::ValidationError, /manifest format errors/) do
            caps.load_manifest(Path[path])
          end
        end
      end
    end
  end
  describe "#request_capability" do
    it "grants capability when prompt handler approves" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.set_prompt_handler do |_capability|
        true
      end
      result = caps.request_capability("fs:read")
      result.should be_true
      caps.check("fs:read").should be_true
    end
    it "denies capability when prompt handler rejects" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.set_prompt_handler do |_capability|
        false
      end
      result = caps.request_capability("fs:write")
      result.should be_false
      caps.check("fs:write").should be_false
    end
    it "passes the capability name to the prompt handler" do
      caps = CrystKit::Security::CapabilitySystem.new
      prompted_capability = nil
      caps.set_prompt_handler do |capability|
        prompted_capability = capability
        true
      end
      caps.request_capability("shell:execute")
      prompted_capability.should eq("shell:execute")
    end
    it "returns false when no prompt handler is set" do
      caps = CrystKit::Security::CapabilitySystem.new
      result = caps.request_capability("http:request")
      result.should be_false
      caps.check("http:request").should be_false
    end
    it "does not grant capability when already granted" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("fs:read")
      prompt_called = false
      caps.set_prompt_handler do |_capability|
        prompt_called = true
        true
      end
      result = caps.request_capability("fs:read")
      result.should be_true
      prompt_called.should be_false
    end
    it "logs a violation when request is denied" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.set_prompt_handler do |_capability|
        false
      end
      caps.request_capability("shell:execute")
      caps.violations.size.should eq(1)
      caps.violations[0].capability.should eq("shell:execute")
    end
  end
  describe "#grant_temporary" do
    it "grants a capability for a specified duration" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant_temporary("fs:read", 1.hour)
      caps.check("fs:read").should be_true
    end
    it "capability expires after the duration" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant_temporary("fs:read", -1.second)
      caps.check("fs:read").should be_false
    end
    it "sets an expiry time on the granted capability" do
      caps = CrystKit::Security::CapabilitySystem.new
      before = Time.utc
      caps.grant_temporary("http:request", 30.minutes)
      after = Time.utc
      granted = caps.query.find { |c| c.name == "http:request" }
      granted.should_not be_nil
      granted = granted.not_nil!
      granted.expires_at.should_not be_nil
      exp = granted.expires_at.not_nil!
      exp.should be > before + 29.minutes
      exp.should be < after + 31.minutes
    end
    it "temporary grant does not appear in query after expiry" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant_temporary("shell:execute", -1.second)
      names = caps.query.map(&.name)
      names.should_not contain("shell:execute")
    end
    it "temporary grant can be revoked before expiry" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant_temporary("fs:write", 1.hour)
      caps.check("fs:write").should be_true
      caps.revoke("fs:write")
      caps.check("fs:write").should be_false
    end
    it "grants capability to a specific window temporarily" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant_temporary_to_window("fs:read", "main", 1.hour)
      caps.check_for_window("fs:read", "main").should be_true
    end
    it "window temporary grant expires" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant_temporary_to_window("fs:read", "main", -1.second)
      caps.check_for_window("fs:read", "main").should be_false
    end
  end
  describe "runtime request with temporary grant" do
    it "request_capability can grant a temporary capability via prompt handler" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.set_prompt_handler do |_capability|
        true
      end
      result = caps.request_capability("fs:read", duration: 5.minutes)
      result.should be_true
      caps.check("fs:read").should be_true
      granted = caps.query.find { |c| c.name == "fs:read" }
      granted.should_not be_nil
      granted.not_nil!.expires_at.should_not be_nil
    end
    it "request_capability without duration grants permanent capability" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.set_prompt_handler do |_capability|
        true
      end
      caps.request_capability("fs:read")
      granted = caps.query.find { |c| c.name == "fs:read" }
      granted.should_not be_nil
      granted.not_nil!.expires_at.should be_nil
    end
  end
end
describe CrystKit::App do
  it "fails startup when a configured capability manifest is invalid" do
    SpecHelpers.with_temp_dir do |dir|
      manifest_path = Path[dir] / "capabilities.json"
      File.write(manifest_path, %({"capabilities":[{"name":"obsolete:shape"}]}))
      expect_raises(CrystKit::Core::ValidationError, /Capability manifest format errors/) do
        CrystKit::App.new(CrystKit::AppConfig.new(
          storage_dir: Path[dir] / "storage",
          capabilities_manifest: manifest_path,
        ))
      end
    end
  end
  it "loads capabilities, window/plugin grants, path scopes, and resource scopes from its manifest" do
    SpecHelpers.with_temp_dir do |dir|
      path_scope = Path[dir] / "documents"
      manifest_path = Path[dir] / "capabilities.json"
      File.write(manifest_path, {
        capabilities: ["fs:read", "http:request"],
        windows:      {"main" => ["fs:read"]},
        scopes:       {
          "fs"   => [path_scope.to_s],
          "http" => ["https://api.example.com/"],
        },
      }.to_json)
      app = CrystKit::App.new(CrystKit::AppConfig.new(
        storage_dir: Path[dir] / "storage",
        capabilities_manifest: manifest_path,
      ))
      app.security.capabilities.check("fs:read").should be_true
      app.security.capabilities.check_for_window("fs:read", "main").should be_true
      app.security.scopes.validate(path_scope / "note.txt", CrystKit::Security::Permission::Read).should be_true
      scope = app.security.resource_scopes["http"]
      scope.should be_a(CrystKit::Security::Scopes::HttpScope)
      scope.as(CrystKit::Security::Scopes::HttpScope).allows?("https://api.example.com/users").should be_true
    end
  end
end
describe CrystKit::Security::ScopeManager do
  describe "#persist and #validate" do
    it "persists and validates a read permission" do
      SpecHelpers.with_temp_file("content") do |file_path|
        manager = CrystKit::Security::ScopeManager.new
        path = Path[file_path]
        manager.persist(path, CrystKit::Security::Permission::Read)
        manager.validate(path, CrystKit::Security::Permission::Read).should be_true
      end
    end
    it "returns false for a path without a scope" do
      manager = CrystKit::Security::ScopeManager.new
      manager.validate(Path["/some/path"], CrystKit::Security::Permission::Read).should be_false
    end
    it "returns false for an expired scope" do
      SpecHelpers.with_temp_file("content") do |file_path|
        manager = CrystKit::Security::ScopeManager.new
        path = Path[file_path]
        manager.persist(path, CrystKit::Security::Permission::Read, expires_at: Time.utc - 1.second)
        manager.validate(path, CrystKit::Security::Permission::Read).should be_false
      end
    end
  end
  describe "#revoke" do
    it "removes a persisted scope" do
      SpecHelpers.with_temp_file("content") do |file_path|
        manager = CrystKit::Security::ScopeManager.new
        path = Path[file_path]
        manager.persist(path, CrystKit::Security::Permission::Read)
        manager.revoke(path)
        manager.has_scope?(path).should be_false
      end
    end
  end
  describe "#query" do
    it "returns all non-expired scopes" do
      SpecHelpers.with_temp_file("a") do |path_a|
        SpecHelpers.with_temp_file("b") do |path_b|
          manager = CrystKit::Security::ScopeManager.new
          manager.persist(Path[path_a], CrystKit::Security::Permission::Read)
          manager.persist(Path[path_b], CrystKit::Security::Permission::Write)
          scopes = manager.query
          scopes.size.should eq(2)
        end
      end
    end
  end
  describe "#cleanup_invalid" do
    it "removes expired scopes" do
      SpecHelpers.with_temp_file("content") do |file_path|
        manager = CrystKit::Security::ScopeManager.new
        path = Path[file_path]
        manager.persist(path, CrystKit::Security::Permission::Read, expires_at: Time.utc - 1.second)
        manager.cleanup_invalid
        manager.has_scope?(path).should be_false
      end
    end
  end
  describe "persistence to disk" do
    it "saves and reloads scopes from disk" do
      SpecHelpers.with_temp_dir do |dir|
        storage_path = Path[dir] / "scopes.json"
        SpecHelpers.with_temp_file("content") do |file_path|
          path = Path[file_path]
          manager1 = CrystKit::Security::ScopeManager.new(storage_path)
          manager1.persist(path, CrystKit::Security::Permission::Read)
          manager2 = CrystKit::Security::ScopeManager.new(storage_path)
          manager2.has_scope?(path).should be_true
        end
      end
    end
  end
  describe "path validation" do
    it "raises for empty path" do
      manager = CrystKit::Security::ScopeManager.new
      expect_raises(CrystKit::Core::SecurityError, /cannot be empty/) do
        manager.persist(Path[""], CrystKit::Security::Permission::Read)
      end
    end
  end
  describe "descendant scopes" do
    it "allows a child path when its parent directory has write scope" do
      SpecHelpers.with_temp_dir do |dir|
        manager = CrystKit::Security::ScopeManager.new
        manager.persist(Path[dir], CrystKit::Security::Permission::Write)
        manager.validate(Path[dir] / "nested" / "file.txt", CrystKit::Security::Permission::Write).should be_true
        manager.validate(Path[dir] / "nested" / "file.txt", CrystKit::Security::Permission::Read).should be_true
      end
    end
  end
end
describe CrystKit::Security::Context do
  it "requires both a capability and a matching path scope" do
    SpecHelpers.with_temp_dir do |dir|
      capabilities = CrystKit::Security::CapabilitySystem.new
      scopes = CrystKit::Security::ScopeManager.new
      context = CrystKit::Security::Context.new(capabilities, scopes)
      path = Path[dir] / "file.txt"
      capabilities.grant("fs:write")
      expect_raises(CrystKit::Core::SecurityError, /Missing scope/) do
        context.require_path!("fs:write", path, CrystKit::Security::Permission::Write)
      end
      scopes.persist(Path[dir], CrystKit::Security::Permission::Write)
      context.require_path!("fs:write", path, CrystKit::Security::Permission::Write)
    end
  end
  it "requires explicit resource scopes in addition to capabilities" do
    capabilities = CrystKit::Security::CapabilitySystem.new
    capabilities.grant("http:request")
    context = CrystKit::Security::Context.new(capabilities)
    expect_raises(CrystKit::Core::SecurityError, /Resource scope denied/) do
      context.require_resource!("http:request", "https://example.com/api")
    end
    context.resource_scopes["http"] = CrystKit::Security::Scopes::HttpScope.new(["https://example.com/*"])
    context.require_resource!("http:request", "https://example.com/api")
  end

  describe "#load_manifest Execute permission for process/shell" do
    it "grants Execute on fs scope paths when process:spawn is declared" do
      SpecHelpers.with_temp_dir do |dir|
        manifest_json = %({"capabilities":["fs:write","process:spawn"],"scopes":{"fs":["#{dir}"]}})
        SpecHelpers.with_temp_file(manifest_json) do |path|
          context = CrystKit::Security::Context.new(
            CrystKit::Security::CapabilitySystem.new,
            CrystKit::Security::ScopeManager.new,
          )
          context.load_manifest(Path[path])
          # Execute must be granted so ProcessManager#spawn can use it as a cwd
          context.scopes.validate(Path[dir], CrystKit::Security::Permission::Execute).should be_true
          # Write is still granted (fs:write declared)
          context.scopes.validate(Path[dir], CrystKit::Security::Permission::Write).should be_true
        end
      end
    end

    it "grants Execute on fs scope paths when shell:execute is declared" do
      SpecHelpers.with_temp_dir do |dir|
        manifest_json = %({"capabilities":["fs:read","shell:execute"],"scopes":{"fs":["#{dir}"]}})
        SpecHelpers.with_temp_file(manifest_json) do |path|
          context = CrystKit::Security::Context.new(
            CrystKit::Security::CapabilitySystem.new,
            CrystKit::Security::ScopeManager.new,
          )
          context.load_manifest(Path[path])
          context.scopes.validate(Path[dir], CrystKit::Security::Permission::Execute).should be_true
        end
      end
    end

    it "does not grant Execute when neither process:spawn nor shell:execute is declared" do
      SpecHelpers.with_temp_dir do |dir|
        manifest_json = %({"capabilities":["fs:write"],"scopes":{"fs":["#{dir}"]}})
        SpecHelpers.with_temp_file(manifest_json) do |path|
          context = CrystKit::Security::Context.new(
            CrystKit::Security::CapabilitySystem.new,
            CrystKit::Security::ScopeManager.new,
          )
          context.load_manifest(Path[path])
          context.scopes.validate(Path[dir], CrystKit::Security::Permission::Execute).should be_false
          context.scopes.validate(Path[dir], CrystKit::Security::Permission::Write).should be_true
        end
      end
    end
  end
end
