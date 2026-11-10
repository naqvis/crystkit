require "../spec_helper"
require "../../src/features/asset_resolution"
require "../../src/features/asset_source"
require "virtualfs"

private def mem_with(files : Hash(String, String)) : VirtualFs::InMemory
  mem = VirtualFs::InMemory.new
  files.each { |path, content| mem.add_file(path, content.to_slice) }
  mem
end

describe CrystKit::Features::AssetResolution do
  describe ".resolve(Path, source)" do
    it "returns IconSource.bytes when the VFS has the path" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"icons/tray.png" => "PNG"}), "/", priority: 0)
      source = CrystKit::Features::VfsAssetSource.new(vfs)

      result = CrystKit::Features::AssetResolution.resolve(Path.new("icons/tray.png"), source)
      result.should_not be_nil
      result.not_nil!.bytes?.should be_true
      String.new(result.not_nil!.bytes.not_nil!).should eq("PNG")
      result.not_nil!.key.should eq("icons/tray.png")
    end

    it "returns nil when the VFS is wired in but misses" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"a.txt" => "x"}), "/", priority: 0)
      source = CrystKit::Features::VfsAssetSource.new(vfs)

      CrystKit::Features::AssetResolution.resolve(Path.new("missing.png"), source).should be_nil
    end

    it "falls back to File.read when no source is wired and the file exists" do
      Dir.mkdir_p("/tmp/crystkit-ar")
      File.write("/tmp/crystkit-ar/fallback.png", "DISKBYTES")
      result = CrystKit::Features::AssetResolution.resolve(Path.new("/tmp/crystkit-ar/fallback.png"), nil)
      result.should_not be_nil
      result.not_nil!.bytes?.should be_true
      String.new(result.not_nil!.bytes.not_nil!).should eq("DISKBYTES")
      result.not_nil!.key.should eq("/tmp/crystkit-ar/fallback.png")
    ensure
      File.delete("/tmp/crystkit-ar/fallback.png") rescue nil
      Dir.delete("/tmp/crystkit-ar") rescue nil
    end

    it "returns nil when no source is wired and the file is missing" do
      CrystKit::Features::AssetResolution.resolve(Path.new("/tmp/crystkit-ar/nope.png"), nil).should be_nil
    end
  end

  describe ".resolve(String, source)" do
    it "returns IconSource.name regardless of source" do
      result = CrystKit::Features::AssetResolution.resolve("edit-delete", nil)
      result.should_not be_nil
      result.not_nil!.name?.should be_true
      result.not_nil!.name.should eq("edit-delete")
    end

    it "returns a name source even with a wired source" do
      vfs = VirtualFs::Vfs.new
      source = CrystKit::Features::VfsAssetSource.new(vfs)
      result = CrystKit::Features::AssetResolution.resolve("media-play", source)
      result.not_nil!.name?.should be_true
    end
  end

  describe ".resolve(String, source) with path-like strings" do
    it "treats strings with file extensions as VFS paths" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"tray.png" => "PNG"}), "/", priority: 0)
      source = CrystKit::Features::VfsAssetSource.new(vfs)

      result = CrystKit::Features::AssetResolution.resolve("tray.png", source)
      result.should_not be_nil
      result.not_nil!.bytes?.should be_true
      String.new(result.not_nil!.bytes.not_nil!).should eq("PNG")
    end

    it "treats strings with slashes as VFS paths" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"icons/save.png" => "SAVE"}), "/", priority: 0)
      source = CrystKit::Features::VfsAssetSource.new(vfs)

      result = CrystKit::Features::AssetResolution.resolve("icons/save.png", source)
      result.should_not be_nil
      result.not_nil!.bytes?.should be_true
    end

    it "treats bare names without extensions as theme names" do
      result = CrystKit::Features::AssetResolution.resolve("edit-delete", nil)
      result.not_nil!.name?.should be_true
      result.not_nil!.name.should eq("edit-delete")
    end
  end

  describe ".resolve(URI, source)" do
    it "returns nil (network is async, handled by AssetFetcher)" do
      CrystKit::Features::AssetResolution.resolve(URI.parse("http://localhost/x.png"), nil).should be_nil
    end
  end
end
