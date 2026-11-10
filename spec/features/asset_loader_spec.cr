require "../spec_helper"
require "../../src/features/asset_loader"
require "virtualfs"
require "file_utils"

describe CrystKit::Features::AssetLoader do
  describe ".load" do
    it "mounts a .vpak found via CRYSTKIT_ASSETS_PAK" do
      SpecHelpers.with_temp_dir do |dir|
        src = File.join(dir, "src")
        Dir.mkdir_p(src)
        File.write(File.join(src, "index.html"), "<h1>Pak</h1>")
        pak_path = File.join(dir, "assets.vpak")
        VirtualFs::PakFormat.build(pak_path, package_id: "test") do |b|
          b.add_dir(src)
        end

        SpecHelpers.with_env("CRYSTKIT_ASSETS_PAK", pak_path) do
          source = CrystKit::Features::AssetLoader.load
          source.should be_a(CrystKit::Features::VfsAssetSource)
          result = source.not_nil!.fetch("/index.html")
          result.should_not be_nil
          String.new(result.not_nil![0]).should eq("<h1>Pak</h1>")
        end
      end
    end

    it "falls back to an OsDir when no pak is found and a frontend dir exists" do
      SpecHelpers.with_temp_dir do |dir|
        frontend = File.join(dir, "frontend")
        Dir.mkdir_p(frontend)
        File.write(File.join(frontend, "index.html"), "<h1>Dev</h1>")

        SpecHelpers.with_env("CRYSTKIT_ASSETS_PAK", nil) do
          source = CrystKit::Features::AssetLoader.load(frontend_dir: frontend)
          source.should be_a(CrystKit::Features::VfsAssetSource)
          result = source.not_nil!.fetch("/index.html")
          String.new(result.not_nil![0]).should eq("<h1>Dev</h1>")
        end
      end
    end

    it "returns nil when no assets are found anywhere" do
      SpecHelpers.with_env("CRYSTKIT_ASSETS_PAK", nil) do
        source = CrystKit::Features::AssetLoader.load(frontend_dir: "/nonexistent-frontend-xyz")
        source.should be_nil
      end
    end

    it "mounts an overlay patch pak at higher priority when present" do
      SpecHelpers.with_temp_dir do |dir|
        src = File.join(dir, "src")
        Dir.mkdir_p(src)
        File.write(File.join(src, "index.html"), "original")
        File.write(File.join(src, "style.css"), "body{}")
        pak_path = File.join(dir, "assets.vpak")
        VirtualFs::PakFormat.build(pak_path, package_id: "test") do |b|
          b.add_dir(src)
        end

        patch_src = File.join(dir, "patch_src")
        Dir.mkdir_p(patch_src)
        File.write(File.join(patch_src, "index.html"), "patched")
        patch_path = File.join(dir, "assets.patch.vpak")
        VirtualFs::PakFormat.build(patch_path, package_id: "patch") do |b|
          b.add_dir(patch_src)
        end

        SpecHelpers.with_env("CRYSTKIT_ASSETS_PAK", pak_path) do
          source = CrystKit::Features::AssetLoader.load
          result = source.not_nil!.fetch("/index.html")
          String.new(result.not_nil![0]).should eq("patched")
          result2 = source.not_nil!.fetch("/style.css")
          String.new(result2.not_nil![0]).should eq("body{}")
        end
      end
    end
  end
end
