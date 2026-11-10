require "./spec_helper"
require "../src/features/window_state"

describe CrystKit::Features::WindowStateStore do
  it "loads existing state file on init" do
    SpecHelpers.with_temp_dir do |dir|
      path = Path[dir] / "states.json"
      File.write(path, %({"main":{"x":100,"y":200,"width":800,"height":600,"maximized":true,"fullscreen":false,"visible":true,"prev_x":0,"prev_y":0}}))
      store = CrystKit::Features::WindowStateStore.new(path)
      store["main"].x.should eq(100)
      store["main"].maximized?.should be_true
    end
  end

  it "starts empty when file does not exist" do
    SpecHelpers.with_temp_dir do |dir|
      store = CrystKit::Features::WindowStateStore.new(Path[dir] / "states.json")
      store["main"]?.should be_nil
    end
  end

  it "starts empty on corrupt file" do
    SpecHelpers.with_temp_dir do |dir|
      path = Path[dir] / "states.json"
      File.write(path, "{{{garbage}}}")
      store = CrystKit::Features::WindowStateStore.new(path)
      store["main"]?.should be_nil
    end
  end

  it "flush persists all entries to disk" do
    SpecHelpers.with_temp_dir do |dir|
      path = Path[dir] / "states.json"
      store = CrystKit::Features::WindowStateStore.new(path)
      store["a"] = CrystKit::Features::WindowStateData.new(width: 1024)
      store["b"] = CrystKit::Features::WindowStateData.new(width: 800)
      store.flush

      reloaded = CrystKit::Features::WindowStateStore.new(path)
      reloaded["a"].width.should eq(1024)
      reloaded["b"].width.should eq(800)
    end
  end

  it "flush overwrites existing file" do
    SpecHelpers.with_temp_dir do |dir|
      path = Path[dir] / "states.json"
      File.write(path, %({"old":{"width":1}}))
      store = CrystKit::Features::WindowStateStore.new(path)
      store["new"] = CrystKit::Features::WindowStateData.new(width: 999)
      store.flush

      reloaded = CrystKit::Features::WindowStateStore.new(path)
      reloaded["old"]?.should be_nil
      reloaded["new"].width.should eq(999)
    end
  end

  it "delete removes entry from cache" do
    SpecHelpers.with_temp_dir do |dir|
      store = CrystKit::Features::WindowStateStore.new(Path[dir] / "states.json")
      store["x"] = CrystKit::Features::WindowStateData.new
      store.delete("x")
      store["x"]?.should be_nil
    end
  end

  it "delete does not affect other entries on flush" do
    SpecHelpers.with_temp_dir do |dir|
      path = Path[dir] / "states.json"
      store = CrystKit::Features::WindowStateStore.new(path)
      store["a"] = CrystKit::Features::WindowStateData.new
      store["b"] = CrystKit::Features::WindowStateData.new
      store.delete("a")
      store.flush

      reloaded = CrystKit::Features::WindowStateStore.new(path)
      reloaded["a"]?.should be_nil
      reloaded["b"].should_not be_nil
    end
  end

  it "flush creates parent directory" do
    SpecHelpers.with_temp_dir do |dir|
      nested = Path[dir] / "sub" / "dir" / "states.json"
      store = CrystKit::Features::WindowStateStore.new(nested)
      store["main"] = CrystKit::Features::WindowStateData.new
      store.flush
      File.exists?(nested).should be_true
    end
  end

  it "mutations through reference are visible in store" do
    SpecHelpers.with_temp_dir do |dir|
      store = CrystKit::Features::WindowStateStore.new(Path[dir] / "states.json")
      store["main"] = CrystKit::Features::WindowStateData.new(width: 800)
      state = store["main"]
      state.width = 1024
      store["main"].width.should eq(1024)
    end
  end
end
