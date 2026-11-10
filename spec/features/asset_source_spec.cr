require "../spec_helper"
require "../../src/features/asset_source"
require "virtualfs"

private def mem_with(files : Hash(String, String)) : VirtualFs::InMemory
  mem = VirtualFs::InMemory.new
  files.each { |path, content| mem.add_file(path, content.to_slice) }
  mem
end

describe CrystKit::Features::VfsAssetSource do
  describe "#fetch" do
    it "returns body bytes and mime for a file in the vfs" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"index.html" => "<h1>Hi</h1>", "app.js" => "console.log(1)"}), "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs)
      result = source.fetch("/index.html")
      result.should_not be_nil
      body, mime = result.not_nil!
      String.new(body).should eq("<h1>Hi</h1>")
      mime.should eq("text/html")
    end

    it "treats bare / as /index.html" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"index.html" => "home"}), "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs)
      result = source.fetch("/")
      String.new(result.not_nil![0]).should eq("home")
    end

    it "uses extension table when entry has no stored mime" do
      vfs = VirtualFs::Vfs.new
      mem = VirtualFs::InMemory.new
      mem.add_file("data.bin", Bytes.new(4) { |i| i.to_u8 })
      vfs.mount(mem, "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs)
      result = source.fetch("/data.bin")
      result.not_nil![1].should eq("application/octet-stream")
    end

    it "returns nil for a missing file" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"index.html" => "x"}), "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs)
      source.fetch("/nope.html").should be_nil
    end

    it "falls back to index.html for extensionless missing paths when spa_fallback is true" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"index.html" => "spa-shell", "about.html" => "about"}), "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs, spa_fallback: true)
      result = source.fetch("/users")
      String.new(result.not_nil![0]).should eq("spa-shell")
    end

    it "does not SPA-fallback when spa_fallback is false" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"index.html" => "spa-shell"}), "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs, spa_fallback: false)
      source.fetch("/users").should be_nil
    end
  end

  describe "#exists?" do
    it "returns true for present files and false for missing ones" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"a.txt" => "hi"}), "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs)
      source.exists?("/a.txt").should be_true
      source.exists?("/b.txt").should be_false
    end
  end

  describe "#read_bytes" do
    it "returns bytes for a file in the vfs" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"icon.png" => "PNGBYTES"}), "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs)
      result = source.read_bytes("/icon.png")
      result.should_not be_nil
      String.new(result.not_nil!).should eq("PNGBYTES")
    end

    it "returns nil for a missing file (no exception)" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"a.txt" => "hi"}), "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs)
      source.read_bytes("/nope.png").should be_nil
    end

    it "does NOT spa-fallback for extensionless paths" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"index.html" => "shell"}), "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs, spa_fallback: true)
      source.read_bytes("/users").should be_nil
    end

    it "does NOT spa-fallback even when spa_fallback is true" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"index.html" => "shell", "icon.png" => "x"}), "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs, spa_fallback: true)
      source.read_bytes("/icon.png").should_not be_nil
      source.read_bytes("/missing").should be_nil
    end
  end

  describe "#size" do
    it "returns the file size in bytes" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"icon.png" => "abcd"}), "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs)
      source.size("/icon.png").should eq(4_i64)
    end

    it "returns nil for a missing file" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"a.txt" => "hi"}), "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs)
      source.size("/nope.png").should be_nil
    end
  end
end
