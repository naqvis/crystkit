require "./spec_helper"
require "../src/ipc/codec"

struct CodecPoint
  include JSON::Serializable
  getter x : Int32
  getter y : Int32
end

enum CodecColor
  Red
  Blue
end
describe CrystKit::IPC::Codec do
  describe "decode" do
    it "decodes a valid JSON object into the target type" do
      point = CrystKit::IPC::Codec.decode(JSON.parse(%({"x":1,"y":2})), CodecPoint)
      point.should be_a(CodecPoint)
      point.x.should eq(1)
      point.y.should eq(2)
    end
    it "raises IPCError with VALIDATION_ERROR on a missing field" do
      error = expect_raises(CrystKit::Core::IPCError) do
        CrystKit::IPC::Codec.decode(JSON.parse(%({"x":1})), CodecPoint)
      end
      error.code.should eq("VALIDATION_ERROR")
    end
    it "raises IPCError when the payload is the wrong type" do
      expect_raises(CrystKit::Core::IPCError) do
        CrystKit::IPC::Codec.decode(JSON.parse(%("hello")), CodecPoint)
      end
    end
  end
  describe "arguments" do
    it "returns the expected number of elements from a JSON array" do
      args = CrystKit::IPC::Codec.arguments(JSON.parse(%([1,2,3])), 3)
      args.should be_a(Array(JSON::Any))
      args.size.should eq(3)
      args[0].raw.should eq(1)
      args[1].raw.should eq(2)
      args[2].raw.should eq(3)
    end
    it "raises IPCError with VALIDATION_ERROR on wrong count" do
      error = expect_raises(CrystKit::Core::IPCError) do
        CrystKit::IPC::Codec.arguments(JSON.parse(%([1,2])), 3)
      end
      error.code.should eq("VALIDATION_ERROR")
    end
    it "raises IPCError with VALIDATION_ERROR when payload is not an array" do
      error = expect_raises(CrystKit::Core::IPCError) do
        CrystKit::IPC::Codec.arguments(JSON.parse(%("hello")), 1)
      end
      error.code.should eq("VALIDATION_ERROR")
    end
  end
  describe "to_json_any" do
    it "passes JSON::Any values through" do
      any = JSON.parse(%({"a":1}))
      CrystKit::IPC::Codec.to_json_any(any).should eq(any)
    end
    it "converts a String to a JSON string" do
      result = CrystKit::IPC::Codec.to_json_any("hello")
      result.should be_a(JSON::Any)
      result.raw.should eq("hello")
    end
    it "converts an Int32 via JSON.parse" do
      result = CrystKit::IPC::Codec.to_json_any(42)
      result.raw.should be_a(Int64)
      result.raw.should eq(42)
    end
    it "Base64-encodes Bytes" do
      result = CrystKit::IPC::Codec.to_json_any(Bytes[1, 2, 3])
      result.raw.should eq(Base64.strict_encode(Bytes[1, 2, 3]))
    end
    it "converts an Enum to its string name" do
      result = CrystKit::IPC::Codec.to_json_any(CodecColor::Red)
      result.raw.should eq("Red")
    end
    it "narrows UInt64 within Int64 range to Int64" do
      result = CrystKit::IPC::Codec.to_json_any(5_u64)
      result.raw.should be_a(Int64)
      result.raw.should eq(5_i64)
    end
    it "degrades large UInt64 to Float64" do
      result = CrystKit::IPC::Codec.to_json_any(UInt64::MAX)
      result.raw.should be_a(Float64)
      result.raw.should eq(UInt64::MAX.to_f64)
    end
    it "recursively converts an Array(String)" do
      result = CrystKit::IPC::Codec.to_json_any(["a", "b"])
      result.as_a?.should_not be_nil
      arr = result.as_a
      arr.size.should eq(2)
      arr[0].raw.should eq("a")
      arr[1].raw.should eq("b")
    end
    it "recursively converts a Hash(String, String)" do
      result = CrystKit::IPC::Codec.to_json_any({"k" => "v"})
      result.as_h["k"].raw.should eq("v")
    end
    it "raises IPCError with SERIALIZATION_FAILED for non-serializable values" do
      error = expect_raises(CrystKit::Core::IPCError) do
        CrystKit::IPC::Codec.to_json_any(Float64::NAN)
      end
      error.code.should eq("SERIALIZATION_FAILED")
    end
  end
end
