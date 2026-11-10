require "../spec_helper"
require "../../src/features/asset_fetcher"

private class FakeHTTPClient < CrystKit::Features::HTTPClient
  getter calls = [] of String
  property next_body : Bytes = Bytes.empty
  property next_error : Exception?

  def initialize
    super(CrystKit::Security::Context.new(
      CrystKit::Security::CapabilitySystem.new,
      CrystKit::Security::ScopeManager.new(nil)))
    @next_body = Bytes.empty
  end

  def get_bytes(url : String, timeout : Time::Span? = nil,
                options : CrystKit::Features::RequestOptions = CrystKit::Features::RequestOptions.new) : Bytes
    @calls << url
    if err = @next_error
      raise err
    end
    @next_body
  end
end

describe CrystKit::Features::AssetFetcher do
  it "fetches async and invokes on_ready with the bytes" do
    fake = FakeHTTPClient.new
    fake.next_body = Bytes[1, 2, 3]
    fetcher = CrystKit::Features::AssetFetcher.new(http_client_factory: -> { fake.as(CrystKit::Features::HTTPClient) })
    received = nil.as(CrystKit::Platform::IconSource?)
    fetcher.fetch_async(URI.parse("http://example.com/x.png"),
      on_ready: ->(src : CrystKit::Platform::IconSource) { received = src; nil })
    20.times do
      break unless received.nil?
      Fiber.yield
      sleep 5.milliseconds
    end
    received.should_not be_nil
    received.not_nil!.bytes.should eq(Bytes[1, 2, 3])
    received.not_nil!.key.should eq("http://example.com/x.png")
    fake.calls.should eq(["http://example.com/x.png"])
  end
  it "serves cache hits without calling the http client again" do
    fake = FakeHTTPClient.new
    fake.next_body = Bytes[9]
    fetcher = CrystKit::Features::AssetFetcher.new(http_client_factory: -> { fake.as(CrystKit::Features::HTTPClient) })
    first = nil.as(CrystKit::Platform::IconSource?)
    second = nil.as(CrystKit::Platform::IconSource?)
    fetcher.fetch_async(URI.parse("http://example.com/c.png"),
      on_ready: ->(src : CrystKit::Platform::IconSource) { first = src; nil })
    20.times { break unless first.nil?; Fiber.yield; sleep 5.milliseconds }
    first.should_not be_nil
    fetcher.fetch_async(URI.parse("http://example.com/c.png"),
      on_ready: ->(src : CrystKit::Platform::IconSource) { second = src; nil })
    second.should_not be_nil
    second.not_nil!.bytes.should eq(Bytes[9])
    fake.calls.size.should eq(1)
  end
  it "invokes on_error when the fetch raises" do
    fake = FakeHTTPClient.new
    fake.next_error = Exception.new("boom")
    fetcher = CrystKit::Features::AssetFetcher.new(http_client_factory: -> { fake.as(CrystKit::Features::HTTPClient) })
    err = nil.as(Exception?)
    fetcher.fetch_async(URI.parse("http://example.com/x.png"),
      on_ready: ->(_src : CrystKit::Platform::IconSource) { },
      on_error: ->(e : Exception) { err = e; nil })
    20.times { break unless err.nil?; Fiber.yield; sleep 5.milliseconds }
    err.should_not be_nil
    err.not_nil!.message.should eq("boom")
  end
  it "evicts the least-recently-used entry when the cache is full" do
    fake = FakeHTTPClient.new
    fake.next_body = Bytes[1]
    fetcher = CrystKit::Features::AssetFetcher.new(http_client_factory: -> { fake.as(CrystKit::Features::HTTPClient) }, cache_max: 1)
    ra = nil.as(CrystKit::Platform::IconSource?)
    fetcher.fetch_async(URI.parse("http://example.com/a.png"),
      on_ready: ->(_src : CrystKit::Platform::IconSource) { ra = _src; nil })
    20.times { break unless ra.nil?; Fiber.yield; sleep 5.milliseconds }
    ra.should_not be_nil
    fake.calls.size.should eq(1)
    rb = nil.as(CrystKit::Platform::IconSource?)
    fetcher.fetch_async(URI.parse("http://example.com/b.png"),
      on_ready: ->(_src : CrystKit::Platform::IconSource) { rb = _src; nil })
    20.times { break unless rb.nil?; Fiber.yield; sleep 5.milliseconds }
    rb.should_not be_nil
    fake.calls.size.should eq(2)
    ra2 = nil.as(CrystKit::Platform::IconSource?)
    fetcher.fetch_async(URI.parse("http://example.com/a.png"),
      on_ready: ->(_src : CrystKit::Platform::IconSource) { ra2 = _src; nil })
    20.times { break unless ra2.nil?; Fiber.yield; sleep 5.milliseconds }
    ra2.should_not be_nil
    fake.calls.size.should eq(3)
    rb2 = nil.as(CrystKit::Platform::IconSource?)
    fetcher.fetch_async(URI.parse("http://example.com/b.png"),
      on_ready: ->(_src : CrystKit::Platform::IconSource) { rb2 = _src; nil })
    20.times { break unless rb2.nil?; Fiber.yield; sleep 5.milliseconds }
    rb2.should_not be_nil
    fake.calls.size.should eq(4)
  end
end
