require "../spec_helper"
require "../../src/platform/icon_source"

describe CrystKit::Platform::IconSource do
  it "builds a bytes source with key" do
    src = CrystKit::Platform::IconSource.bytes(Bytes.new(3, 0_u8), key: "icons/a.png")
    src.bytes?.should be_true
    src.path?.should be_false
    src.name?.should be_false
    src.bytes.should eq(Bytes.new(3, 0_u8))
    src.key.should eq("icons/a.png")
  end

  it "builds a bytes source without a key" do
    src = CrystKit::Platform::IconSource.bytes(Bytes.new(1, 255_u8))
    src.bytes?.should be_true
    src.key.should be_nil
  end

  it "builds a name source" do
    src = CrystKit::Platform::IconSource.name("edit-delete")
    src.name?.should be_true
    src.bytes?.should be_false
    src.name.should eq("edit-delete")
    src.key.should be_nil
  end

  it "bytes and name are mutually exclusive" do
    b = CrystKit::Platform::IconSource.bytes(Bytes.empty)
    b.name.should be_nil
    n = CrystKit::Platform::IconSource.name("x")
    n.bytes.should be_nil
  end
end
