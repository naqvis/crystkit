require "./spec_helper"
require "../src/ipc/policy"

describe CrystKit::IPC::ResourceRule do
  it "extracts top-level object resources" do
    rule = CrystKit::IPC::ResourceRule.new(
      capability: "fs:read",
      kind: CrystKit::IPC::ResourceKind::Path,
      json_path: "path",
      permission: CrystKit::IPC::ResourcePermission::Read,
    )

    rule.extract(JSON.parse(%({"path":"/tmp/a.txt"}))).should eq("/tmp/a.txt")
  end

  it "extracts the complete payload when json_path is empty" do
    rule = CrystKit::IPC::ResourceRule.new(
      capability: "external:open",
      kind: CrystKit::IPC::ResourceKind::Resource,
      json_path: "",
    )

    rule.extract(JSON.parse(%("https://example.com"))).should eq("https://example.com")
  end

  it "extracts positional array resources" do
    rule = CrystKit::IPC::ResourceRule.new(
      capability: "http:request",
      kind: CrystKit::IPC::ResourceKind::Resource,
      json_path: "0",
    )

    rule.extract(JSON.parse(%(["https://example.com", {"method":"GET"}]))).should eq("https://example.com")
  end

  it "extracts nested object resources" do
    rule = CrystKit::IPC::ResourceRule.new(
      capability: "fs:write",
      kind: CrystKit::IPC::ResourceKind::Path,
      json_path: "file.path",
      permission: CrystKit::IPC::ResourcePermission::Write,
    )

    rule.extract(JSON.parse(%({"file":{"path":"~/out.txt"}}))).should eq("~/out.txt")
  end

  it "raises a validation error when a resource is missing" do
    rule = CrystKit::IPC::ResourceRule.new(
      capability: "fs:read",
      kind: CrystKit::IPC::ResourceKind::Path,
      json_path: "path",
      permission: CrystKit::IPC::ResourcePermission::Read,
    )

    expect_raises(CrystKit::Core::IPCError, /Missing IPC policy resource 'path'/) do
      rule.extract(JSON.parse(%({"other":true})))
    end
  end
end

describe CrystKit::IPC::PolicyCatalog do
  it "declares explicit capability policy without relying on command names" do
    catalog = CrystKit::IPC::PolicyCatalog.new
      .require("notes.list", "notes:read")

    catalog.commands["notes.list"].capability.should eq("notes:read")
  end
end

describe CrystKit::IPC::CommandPolicy do
  it "builds public policy without a capability" do
    policy = CrystKit::IPC::CommandPolicy.public

    policy.capability.should be_nil
    policy.risk.should eq(CrystKit::IPC::RiskLevel::Public)
    policy.resources.should be_empty
  end
end
