require "./spec_helper"
require "../src/features/store"

def make_store(dir : String)
  CrystKit::Features::Store.new("test", Path[dir])
end

describe CrystKit::Features::Store do
  it "stores and retrieves a string value" do
    SpecHelpers.with_temp_dir do |dir|
      store = make_store(dir)
      store.set("name", "Alice")
      store.get("name").not_nil!.as_s.should eq("Alice")
    end
  end
  it "stores and retrieves an integer value" do
    SpecHelpers.with_temp_dir do |dir|
      store = make_store(dir)
      store.set("count", 42)
      store.get("count").not_nil!.as_i.should eq(42)
    end
  end
  it "stores and retrieves a boolean value" do
    SpecHelpers.with_temp_dir do |dir|
      store = make_store(dir)
      store.set("flag", true)
      store.get("flag").not_nil!.as_bool.should be_true
    end
  end
  it "stores and retrieves a JSON object" do
    SpecHelpers.with_temp_dir do |dir|
      store = make_store(dir)
      obj = JSON.parse(%({"x": 1, "y": 2}))
      store.set("point", obj)
      result = store.get("point").not_nil!
      result["x"].as_i.should eq(1)
      result["y"].as_i.should eq(2)
    end
  end
  it "returns nil for missing key" do
    SpecHelpers.with_temp_dir do |dir|
      store = make_store(dir)
      store.get("nonexistent").should be_nil
    end
  end
  it "returns default for missing key" do
    SpecHelpers.with_temp_dir do |dir|
      store = make_store(dir)
      default = JSON::Any.new("fallback")
      store.get("missing", default).as_s.should eq("fallback")
    end
  end
  it "deletes a value" do
    SpecHelpers.with_temp_dir do |dir|
      store = make_store(dir)
      store.set("temp", "value")
      store.delete("temp")
      store.get("temp").should be_nil
    end
  end
  it "checks key existence" do
    SpecHelpers.with_temp_dir do |dir|
      store = make_store(dir)
      store.set("exists", "yes")
      store.has_key?("exists").should be_true
      store.has_key?("missing").should be_false
    end
  end
  it "lists all keys" do
    SpecHelpers.with_temp_dir do |dir|
      store = make_store(dir)
      store.set("a", "1")
      store.set("b", "2")
      store.set("c", "3")
      store.keys.sort!.should eq(["a", "b", "c"])
    end
  end
  it "clears all data" do
    SpecHelpers.with_temp_dir do |dir|
      store = make_store(dir)
      store.set("x", "1")
      store.set("y", "2")
      store.clear
      store.size.should eq(0)
      store.keys.should be_empty
    end
  end
  it "persists data across store instances" do
    SpecHelpers.with_temp_dir do |dir|
      store1 = make_store(dir)
      store1.set("persistent", "value")
      store2 = make_store(dir)
      store2.get("persistent").not_nil!.as_s.should eq("value")
    end
  end
  it "isolates namespaces" do
    SpecHelpers.with_temp_dir do |dir|
      store_a = CrystKit::Features::Store.new("ns_a", Path[dir])
      store_b = CrystKit::Features::Store.new("ns_b", Path[dir])
      store_a.set("key", "from_a")
      store_b.set("key", "from_b")
      store_a.get("key").not_nil!.as_s.should eq("from_a")
      store_b.get("key").not_nil!.as_s.should eq("from_b")
    end
  end
  it "handles concurrent access safely" do
    SpecHelpers.with_temp_dir do |dir|
      store = make_store(dir)
      done = Channel(Nil).new(10)
      10.times do |i|
        spawn do
          store.set("key_#{i}", i.to_s)
          done.send(nil)
        end
      end
      10.times { done.receive }
      store.size.should eq(10)
    end
  end
end
