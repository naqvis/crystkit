require "./spec_helper"
require "../src/features/fs"
require "../src/security/capability"
require "../src/security/scope"

private def make_fs
  caps = CrystKit::Security::CapabilitySystem.new
  caps.grant("fs:read")
  caps.grant("fs:write")
  caps.grant("fs:delete")
  scopes = CrystKit::Security::ScopeManager.new
  SpecHelpers.persist_test_root(scopes, CrystKit::Security::Permission::Write)
  CrystKit::Features::FileSystem.new(caps, scopes)
end

describe CrystKit::Features::FileSystem do
  it "reads and writes text files" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      path = Path[dir] / "test.txt"
      fs.write_text(path, "hello world")
      fs.read_text(path).should eq("hello world")
    end
  end

  it "reads and writes binary files" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      path = Path[dir] / "test.bin"
      data = Bytes[1, 2, 3, 4, 5]
      fs.write_binary(path, data)
      fs.read_binary(path).should eq(data)
    end
  end

  it "streams reads via open_read without loading the whole file" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      path = Path[dir] / "large.txt"
      lines = Array.new(100) { |i| "line-#{i}" }
      fs.write_text(path, lines.join("\n") + "\n")

      collected = [] of String
      fs.open_read(path) do |io|
        io.each_line { |line| collected << line }
      end

      collected.should eq(lines)
    end
  end

  it "streams reads in binary chunks via open_read" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      path = Path[dir] / "data.bin"
      content = Bytes.new(256) { |i| (i & 0xFF).to_u8 }
      fs.write_binary(path, content)

      collected = IO::Memory.new
      fs.open_read(path) do |io|
        IO.copy(io, collected)
      end

      collected.to_slice.should eq(content)
    end
  end

  it "streams writes via open_write incrementally" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      path = Path[dir] / "output.txt"
      fs.open_write(path) do |io|
        10.times { |i| io.puts "row #{i}" }
      end

      fs.read_text(path).lines.map(&.chomp).should eq((0...10).map { |i| "row #{i}" })
    end
  end

  it "open_read raises FILE_NOT_FOUND for missing files" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      expect_raises(CrystKit::Core::FileSystemError, /File not found/) do
        fs.open_read(Path[dir] / "nope.txt", &.gets_to_end)
      end
    end
  end

  it "open_read raises SecurityError without fs:read capability" do
    caps = CrystKit::Security::CapabilitySystem.new
    scopes = CrystKit::Security::ScopeManager.new
    SpecHelpers.persist_test_root(scopes, CrystKit::Security::Permission::Read)
    fs = CrystKit::Features::FileSystem.new(caps, scopes)

    expect_raises(CrystKit::Core::SecurityError, /Missing capability: fs:read/) do
      fs.open_read(Path["/tmp/test.txt"], &.gets_to_end)
    end
  end

  it "open_write raises SecurityError without fs:write capability" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("fs:read")
    scopes = CrystKit::Security::ScopeManager.new
    SpecHelpers.persist_test_root(scopes, CrystKit::Security::Permission::Write)
    fs = CrystKit::Features::FileSystem.new(caps, scopes)

    expect_raises(CrystKit::Core::SecurityError, /Missing capability: fs:write/) do
      fs.open_write(Path["/tmp/test.txt"], &.puts("x"))
    end
  end

  it "creates directories recursively" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      path = Path[dir] / "a" / "b" / "c"
      fs.create_dir(path, recursive: true)
      Dir.exists?(path.to_s).should be_true
    end
  end

  it "deletes a file" do
    SpecHelpers.with_temp_file("content") do |file|
      fs = make_fs
      fs.remove_file(Path[file])
      File.exists?(file).should be_false
    end
  end

  it "deletes a directory recursively" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      sub = Path[dir] / "sub"
      Dir.mkdir(sub.to_s)
      File.write((sub / "file.txt").to_s, "x")
      fs.remove_dir(sub, recursive: true)
      Dir.exists?(sub.to_s).should be_false
    end
  end

  it "trashes a file" do
    SpecHelpers.with_temp_file("trash me") do |file|
      fs = make_fs
      fs.trash_delete(Path[file])
      File.exists?(file).should be_false
    end
  end

  it "trashes a directory with contents" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      target = Path[dir] / "to_trash"
      Dir.mkdir(target.to_s)
      File.write((target / "file.txt").to_s, "x")
      fs.trash_delete(target)
      Dir.exists?(target.to_s).should be_false
    end
  end

  it "trash_delete raises FILE_NOT_FOUND for missing paths" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      expect_raises(CrystKit::Core::FileSystemError, /File not found/) do
        fs.trash_delete(Path[dir] / "nope.txt")
      end
    end
  end

  it "trash_delete raises SecurityError without fs:delete capability" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("fs:read")
    caps.grant("fs:write")
    scopes = CrystKit::Security::ScopeManager.new
    SpecHelpers.persist_test_root(scopes, CrystKit::Security::Permission::Write)
    fs = CrystKit::Features::FileSystem.new(caps, scopes)

    SpecHelpers.with_temp_file("x") do |file|
      expect_raises(CrystKit::Core::SecurityError, /Missing capability: fs:delete/) do
        fs.trash_delete(Path[file])
      end
    end
  end

  it "copies a file" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      src = Path[dir] / "src.txt"
      dst = Path[dir] / "dst.txt"
      File.write(src.to_s, "copy me")
      fs.copy(src, dst)
      File.read(dst.to_s).should eq("copy me")
    end
  end

  it "raises when copy destination exists" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      src = Path[dir] / "src.txt"
      dst = Path[dir] / "dst.txt"
      File.write(src.to_s, "a")
      File.write(dst.to_s, "b")
      expect_raises(CrystKit::Core::FileSystemError, /Destination already exists/) do
        fs.copy(src, dst)
      end
    end
  end

  it "moves a file" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      src = Path[dir] / "src.txt"
      dst = Path[dir] / "dst.txt"
      File.write(src.to_s, "move me")
      fs.move(src, dst)
      File.exists?(src.to_s).should be_false
      File.read(dst.to_s).should eq("move me")
    end
  end

  it "raises when move destination exists" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      src = Path[dir] / "src.txt"
      dst = Path[dir] / "dst.txt"
      File.write(src.to_s, "a")
      File.write(dst.to_s, "b")
      expect_raises(CrystKit::Core::FileSystemError, /Destination already exists/) do
        fs.move(src, dst)
      end
    end
  end

  it "lists directory contents" do
    SpecHelpers.with_temp_dir do |dir|
      fs = make_fs
      File.write(Path[dir].join("a.txt").to_s, "a")
      File.write(Path[dir].join("b.txt").to_s, "b")
      entries = fs.list_dir(Path[dir])
      names = entries.map(&.name).sort!
      names.should contain("a.txt")
      names.should contain("b.txt")
    end
  end

  it "checks file existence" do
    SpecHelpers.with_temp_file("x") do |file|
      fs = make_fs
      fs.exists?(Path[file]).should be_true
      fs.exists?(Path[file + ".nonexistent"]).should be_false
    end
  end

  it "reads file metadata" do
    SpecHelpers.with_temp_file("hello") do |file|
      fs = make_fs
      meta = fs.metadata(Path[file])
      meta.size.should eq(5)
    end
  end

  it "raises when reading without fs:read capability" do
    caps = CrystKit::Security::CapabilitySystem.new
    scopes = CrystKit::Security::ScopeManager.new
    fs = CrystKit::Features::FileSystem.new(caps, scopes)
    expect_raises(CrystKit::Core::SecurityError, /Missing capability: fs:read/) do
      fs.read_text(Path["/tmp/test.txt"])
    end
  end

  it "raises when reading without a matching path scope" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("fs:read")
    fs = CrystKit::Features::FileSystem.new(caps, CrystKit::Security::ScopeManager.new)

    expect_raises(CrystKit::Core::SecurityError, /Missing scope/) do
      fs.read_text(Path["/tmp/test.txt"])
    end
  end

  it "raises FileSystemError for missing file" do
    fs = make_fs
    expect_raises(CrystKit::Core::FileSystemError, /File not found/) do
      fs.read_text(Path["/nonexistent/path/file.txt"])
    end
  end
end
