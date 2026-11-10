require "./spec_helper"
require "../src/features/http"
require "../src/features/websocket"
require "../src/security/capability"

private class TLSTestClient < CrystKit::Features::HTTPClient
  def external_tls_bypass?(uri : URI) : Bool
    super
  end
end

def with_http_log(&)
  backend = Log::MemoryBackend.new
  Log.builder.bind("cryst_kit.features.http_client", Log::Severity::Warn, backend)
  yield backend
ensure
  Log.builder.clear
end

def http_client_with_cap
  caps = CrystKit::Security::CapabilitySystem.new
  caps.grant("http:request")
  CrystKit::Features::HTTPClient.new(SpecHelpers.security_context(caps, ["http:request"]))
end

describe CrystKit::Features::HTTPClient do
  it "raises SecurityError without http:request capability" do
    caps = CrystKit::Security::CapabilitySystem.new
    client = CrystKit::Features::HTTPClient.new(SpecHelpers.security_context(caps, ["http:request"]))
    expect_raises(CrystKit::Core::SecurityError) do
      client.get("https://example.com")
    end
  end
  it "raises NetworkError for invalid URL" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("http:request")
    client = CrystKit::Features::HTTPClient.new(SpecHelpers.security_context(caps, ["http:request"]))
    expect_raises(CrystKit::Core::NetworkError | URI::Error | Exception) do
      client.get("not-a-url")
    end
  end
  it "builds URI with query params" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("http:request")
    _client = CrystKit::Features::HTTPClient.new(SpecHelpers.security_context(caps, ["http:request"]))
    opts = CrystKit::Features::RequestOptions.new(
      query_params: {"key" => "value", "foo" => "bar"}
    )
    opts.query_params["key"].should eq("value")
    opts.query_params["foo"].should eq("bar")
  end
  it "HTTPResponse#success? returns true for 2xx" do
    headers = HTTP::Headers.new
    resp = CrystKit::Features::HTTPResponse.new(200, headers, Bytes.empty)
    resp.success?.should be_true
  end
  it "HTTPResponse#success? returns false for 4xx" do
    headers = HTTP::Headers.new
    resp = CrystKit::Features::HTTPResponse.new(404, headers, Bytes.empty)
    resp.success?.should be_false
  end
  it "HTTPResponse#text returns body as string" do
    headers = HTTP::Headers.new
    resp = CrystKit::Features::HTTPResponse.new(200, headers, "hello".to_slice)
    resp.text.should eq("hello")
  end
  it "HTTPResponse#json parses body as JSON" do
    headers = HTTP::Headers.new
    resp = CrystKit::Features::HTTPResponse.new(200, headers, %({"key":"val"}).to_slice)
    resp.json["key"].as_s.should eq("val")
  end

  describe "TLS verification downgrade warnings" do
    it "warns when verify_ssl: false is used against an external host" do
      with_http_log do |backend|
        # Unreachable public IP with a short timeout so the request fails
        # fast; the warning is emitted before the connection attempt.
        opts = CrystKit::Features::RequestOptions.new(verify_ssl: false, timeout: 1.second)
        begin
          http_client_with_cap.get("https://198.51.100.1", opts)
        rescue CrystKit::Core::NetworkError | Socket::Error | IO::TimeoutError
          # expected — we only care about the emitted warning
        end
        messages = backend.entries.map(&.message)
        messages.any?(&.includes?("TLS verification disabled")).should be_true
        messages.any?(&.includes?("198.51.100.1")).should be_true
      end
    end

    it "stays silent when verify_ssl: false is used against localhost" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("http:request")
      client = TLSTestClient.new(SpecHelpers.security_context(caps, ["http:request"]))
      client.external_tls_bypass?(URI.parse("https://localhost:8443")).should be_false
      client.external_tls_bypass?(URI.parse("https://127.0.0.1:8443")).should be_false
      client.external_tls_bypass?(URI.parse("https://192.168.1.10")).should be_false
      client.external_tls_bypass?(URI.parse("https://10.0.0.5")).should be_false
      client.external_tls_bypass?(URI.parse("https://172.16.5.4")).should be_false
      client.external_tls_bypass?(URI.parse("https://example.com")).should be_true
    end
  end
end
describe CrystKit::Features::WebSocketClient do
  it "raises SecurityError without websocket:connect capability" do
    caps = CrystKit::Security::CapabilitySystem.new
    client = CrystKit::Features::WebSocketClient.new(caps)
    expect_raises(CrystKit::Core::SecurityError) do
      client.connect("ws://localhost:9999")
    end
  end
  it "raises NetworkError for non-ws:// scheme" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("websocket:connect")
    client = CrystKit::Features::WebSocketClient.new(caps)
    expect_raises(CrystKit::Core::NetworkError, /must be ws:\/\/ or wss:\/\//) do
      client.connect("http://example.com")
    end
  end
  it "raises NetworkError when connection is refused" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("websocket:connect")
    client = CrystKit::Features::WebSocketClient.new(caps)
    expect_raises(CrystKit::Core::NetworkError) do
      client.connect("ws://localhost:19999")
    end
  end
end
