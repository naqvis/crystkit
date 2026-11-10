require "./spec_helper"
require "../src/features/custom_protocol"
describe CrystKit::Features::CustomProtocol do
  it "works without capabilities" do
    opts = CrystKit::Features::ProtocolOptions.new(scheme: "test")
    _proto = CrystKit::Features::CustomProtocol.new(opts)
  end
  it "resolves URLs via custom resolver" do
    resolver = ->(path : String, _headers : HTTP::Headers) : String? {
      path == "/data.json" ? %({"key":"value"}) : nil
    }
    opts = CrystKit::Features::ProtocolOptions.new(
      scheme: "test",
      resolver: resolver,
    )
    proto = CrystKit::Features::CustomProtocol.new(opts)
    uri = URI.parse("test:///data.json")
    result = proto.resolve(uri)
    result.should_not be_nil
    body, mime = result.not_nil!
    String.new(body).should eq(%({"key":"value"}))
    mime.should eq("application/json")
  end
  it "resolves index.html for root path" do
    SpecHelpers.with_temp_dir do |dir|
      File.write(Path[dir] / "index.html", "<h1>Hello</h1>")
      opts = CrystKit::Features::ProtocolOptions.new(
        scheme: "app",
        serve_assets: true,
        asset_root: Path[dir],
      )
      proto = CrystKit::Features::CustomProtocol.new(opts)
      uri = URI.parse("app:///")
      result = proto.resolve(uri)
      result.should_not be_nil
      body, mime = result.not_nil!
      String.new(body).should eq("<h1>Hello</h1>")
      mime.should eq("text/html")
    end
  end
  it "returns nil for unresolvable URLs" do
    resolver = ->(_path : String, _headers : HTTP::Headers) : String? { nil }
    opts = CrystKit::Features::ProtocolOptions.new(
      scheme: "test",
      resolver: resolver,
    )
    proto = CrystKit::Features::CustomProtocol.new(opts)
    uri = URI.parse("test:///unknown.txt")
    proto.resolve(uri).should be_nil
  end
  it "falls through resolver → asset serving → nil" do
    SpecHelpers.with_temp_dir do |dir|
      resolver = ->(_path : String, _headers : HTTP::Headers) : String? { nil }
      File.write(Path[dir] / "exists.txt", "found")
      opts = CrystKit::Features::ProtocolOptions.new(
        scheme: "app",
        serve_assets: true,
        asset_root: Path[dir],
        resolver: resolver,
      )
      proto = CrystKit::Features::CustomProtocol.new(opts)
      uri = URI.parse("app:///exists.txt")
      result = proto.resolve(uri)
      result.should_not be_nil
      body, _ = result.not_nil!
      String.new(body).should eq("found")
      uri2 = URI.parse("app:///missing.txt")
      proto.resolve(uri2).should be_nil
    end
  end
  it "returns correct MIME types for common extensions" do
    SpecHelpers.with_temp_dir do |dir|
      File.write(Path[dir] / "style.css", "body {}")
      File.write(Path[dir] / "app.js", "console.log(1)")
      opts = CrystKit::Features::ProtocolOptions.new(
        scheme: "app",
        serve_assets: true,
        asset_root: Path[dir],
      )
      proto = CrystKit::Features::CustomProtocol.new(opts)
      css_uri = URI.parse("app:///style.css")
      _, css_mime = proto.resolve(css_uri).not_nil!
      css_mime.should eq("text/css")
      js_uri = URI.parse("app:///app.js")
      _, js_mime = proto.resolve(js_uri).not_nil!
      js_mime.should eq("application/javascript")
    end
  end
end
