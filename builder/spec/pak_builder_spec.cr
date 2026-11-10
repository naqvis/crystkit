require "./spec_helper"
require "../../src/builder/bundle/pak_builder"
require "virtualfs"

describe CrystKit::Builder::Bundle::PakBuilder do
  describe ".build" do
    it "creates a .vpak from a frontend dist directory" do
      SpecHelpers.with_temp_dir do |dir|
        dist = File.join(dir, "dist")
        Dir.mkdir_p(dist)
        File.write(File.join(dist, "index.html"), "<h1>Hello</h1>")
        File.write(File.join(dist, "app.js"), "console.log(1)")
        File.write(File.join(dist, "style.css"), "body{}")
        out_path = File.join(dir, "out", "assets.vpak")

        CrystKit::Builder::Bundle::PakBuilder.build(dist, out_path,
          compress: :deflate, chunk_size: 262_144, package_id: "test-app")

        File.exists?(out_path).should be_true
        info = VirtualFs::PakFormat.info(out_path)
        info.file_count.should eq(3)
      end
    end

    it "is a no-op returning nil when the dist dir does not exist" do
      SpecHelpers.with_temp_dir do |dir|
        out_path = File.join(dir, "out", "assets.vpak")
        result = CrystKit::Builder::Bundle::PakBuilder.build("/nonexistent-xyz", out_path)
        result.should be_nil
        File.exists?(out_path).should be_false
      end
    end

    it "mounts and reads back correctly via Vfs" do
      SpecHelpers.with_temp_dir do |dir|
        dist = File.join(dir, "dist")
        Dir.mkdir_p(dist)
        File.write(File.join(dist, "index.html"), "<h1>Roundtrip</h1>")
        out_path = File.join(dir, "assets.vpak")

        CrystKit::Builder::Bundle::PakBuilder.build(dist, out_path,
          compress: :none, chunk_size: 262_144, package_id: "rt")

        vfs = VirtualFs::Vfs.new
        vfs.mount(VirtualFs::Pak.new(out_path), "/", priority: 0)
        vfs.read("index.html").should eq("<h1>Roundtrip</h1>")
      end
    end
  end
end
