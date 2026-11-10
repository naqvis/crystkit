require "./spec_helper"
require "../src/features/file_watcher"

describe CrystKit::Features::FileWatcher do
  it "delivers shard events only to matching watched roots" do
    SpecHelpers.with_temp_dir do |dir|
      src = File.join(dir, "src")
      frontend = File.join(dir, "frontend")
      Dir.mkdir(src)
      Dir.mkdir(frontend)

      watcher = CrystKit::Features::FileWatcher.new(poll_interval: 20.milliseconds)
      src_events = watcher.watch(src)
      frontend_events = watcher.watch(frontend)
      File.write(File.join(src, "main.cr"), "puts 1")

      event = src_events.receive
      event.path.should eq(File.realpath(File.join(src, "main.cr")))
      select
      when frontend_events.receive
        fail "event leaked to an unrelated watch"
      when timeout(100.milliseconds)
      end
      watcher.close
    end
  end

  it "preserves old_path for renames" do
    SpecHelpers.with_temp_dir do |dir|
      old_path = File.join(dir, "old.txt")
      new_path = File.join(dir, "new.txt")
      File.write(old_path, "data")
      old_real = File.realpath(old_path)

      watcher = CrystKit::Features::FileWatcher.new(poll_interval: 20.milliseconds)
      events = watcher.watch(dir)
      sleep 50.milliseconds
      File.rename(old_path, new_path)

      event = events.receive
      event.type.should eq("renamed")
      event.path.should eq(File.realpath(new_path))
      event.old_path.should eq(old_real)
      watcher.close
    end
  end

  it "closes idempotently" do
    watcher = CrystKit::Features::FileWatcher.new
    watcher.close
    watcher.close
  end
end
