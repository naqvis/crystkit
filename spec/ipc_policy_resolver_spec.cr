require "./spec_helper"
require "../src/ipc/policy_resolver"

describe CrystKit::IPC::PolicyResolver do
  it "uses plugin metadata policy before the public default" do
    resolver = CrystKit::IPC::PolicyResolver.new
    resolver.register_plugin("vault.get", CrystKit::IPC::CommandPolicy.new(capability: "secrets:read"))

    resolver.resolve("vault.get").capability.should eq("secrets:read")
  end

  it "defaults unresolved commands to public policy instead of guessing from names" do
    resolver = CrystKit::IPC::PolicyResolver.new

    resolver.resolve("notes.list").risk.should eq(CrystKit::IPC::RiskLevel::Public)
    resolver.resolve("notes.list").capability.should be_nil
    resolver.resolve("notes.create").resources.should be_empty
  end

  it "uses config overrides before all other sources" do
    resolver = CrystKit::IPC::PolicyResolver.new
    resolver.register_plugin("notes.list", CrystKit::IPC::CommandPolicy.new(capability: "plugin:read"))
    resolver.register_override("notes.list", CrystKit::IPC::CommandPolicy.new(capability: "override:read"))

    resolver.resolve("notes.list").capability.should eq("override:read")
  end

  it "uses config overrides for app commands that want pre-handler policy" do
    resolver = CrystKit::IPC::PolicyResolver.new
    resolver.register_override("notes.sync_everything", CrystKit::IPC::CommandPolicy.new(capability: "notes:write"))

    resolver.resolve("notes.sync_everything").capability.should eq("notes:write")
  end
end
