require "../spec_helper"
require "../../src/features/custom_protocol"
require "../../src/features/asset_source"
require "virtualfs"

class FakeBackend < CrystKit::Platform::CustomProtocolBackend
  getter setup_args : {String, Proc(String, {Bytes, String}?)}?
  getter register_args : {String, Proc(String, {Bytes, String}?)}?

  def setup(scheme : String, resolver : Proc(String, {Bytes, String}?)) : Nil
    @setup_args = {scheme, resolver}
  end

  def register(window : T, scheme : String, resolver : Proc(String, {Bytes, String}?)) : Nil forall T
    @register_args = {scheme, resolver}
  end
end

describe CrystKit::Features::CustomProtocol do
  describe "unified resolver built from asset_source" do
    it "resolves paths via the asset_source" do
      vfs = VirtualFs::Vfs.new
      mem = VirtualFs::InMemory.new
      mem.add_file("index.html", "<h1>App</h1>".to_slice)
      vfs.mount(mem, "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs)
      opts = CrystKit::Features::ProtocolOptions.new("crystkit")
      opts.asset_source = source
      backend = FakeBackend.new
      proto = CrystKit::Features::CustomProtocol.new(opts, backend)
      proto.setup

      _scheme, resolver = backend.setup_args.not_nil!
      result = resolver.call("/index.html")
      result.should_not be_nil
      String.new(result.not_nil![0]).should eq("<h1>App</h1>")
      result.not_nil![1].should eq("text/html")
    end

    it "returns nil for a missing path" do
      vfs = VirtualFs::Vfs.new
      mem = VirtualFs::InMemory.new
      mem.add_file("index.html", "x".to_slice)
      vfs.mount(mem, "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs)
      opts = CrystKit::Features::ProtocolOptions.new("crystkit")
      opts.asset_source = source
      backend = FakeBackend.new
      proto = CrystKit::Features::CustomProtocol.new(opts, backend)
      proto.setup

      _scheme, resolver = backend.setup_args.not_nil!
      resolver.call("/missing.html").should be_nil
    end

    it "user resolver proc takes precedence over asset_source" do
      vfs = VirtualFs::Vfs.new
      mem = VirtualFs::InMemory.new
      mem.add_file("index.html", "from-vfs".to_slice)
      vfs.mount(mem, "/", priority: 0)

      source = CrystKit::Features::VfsAssetSource.new(vfs)
      opts = CrystKit::Features::ProtocolOptions.new("crystkit")
      opts.resolver = Proc(String, HTTP::Headers, String?).new do |path, _hdr|
        "custom:#{path}"
      end
      opts.asset_source = source
      backend = FakeBackend.new
      proto = CrystKit::Features::CustomProtocol.new(opts, backend)
      proto.setup

      _scheme, resolver = backend.setup_args.not_nil!
      result = resolver.call("/index.html")
      String.new(result.not_nil![0]).should eq("custom:/index.html")
    end
  end
end
