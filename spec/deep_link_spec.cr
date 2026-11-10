require "./spec_helper"
require "../src/features/deep_link"

private class FakeURLSchemeProvider < CrystKit::Features::URLSchemeProvider
  getter registered = [] of String
  getter unregistered = [] of String

  def register_scheme(scheme : String, app_name : String, app_exec : String) : Nil
    @registered << scheme
  end

  def unregister_scheme(scheme : String) : Nil
    @unregistered << scheme
  end
end

private def deep_link : CrystKit::Features::DeepLink
  CrystKit::Features::DeepLink.new(provider: FakeURLSchemeProvider.new)
end

describe CrystKit::Features::DeepLink do
  describe "#register_scheme" do
    it "delegates OS registration through the injected platform backend" do
      provider = FakeURLSchemeProvider.new
      dl = CrystKit::Features::DeepLink.new(provider: provider)
      dl.register_scheme("myapp")
      dl.unregister_scheme("myapp")
      provider.registered.should eq(["myapp"])
      provider.unregistered.should eq(["myapp"])
    end
    it "registers a valid alphanumeric scheme" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.registered?("myapp").should be_true
    end
    it "registers multiple schemes per application" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.register_scheme("myapp2")
      dl.registered_schemes.should contain("myapp")
      dl.registered_schemes.should contain("myapp2")
    end
    it "normalizes scheme to lowercase on registration" do
      dl = deep_link
      dl.register_scheme("MyApp")
      dl.registered?("myapp").should be_true
      dl.registered?("MyApp").should be_true
    end
    it "raises when registering the same scheme twice" do
      dl = deep_link
      dl.register_scheme("myapp")
      expect_raises(CrystKit::Core::Error, /already registered/) do
        dl.register_scheme("myapp")
      end
    end
    it "raises when registering the same scheme with different case" do
      dl = deep_link
      dl.register_scheme("myapp")
      expect_raises(CrystKit::Core::Error, /already registered/) do
        dl.register_scheme("MYAPP")
      end
    end
  end
  describe "#validate_scheme!" do
    it "accepts a single alphanumeric character" do
      dl = deep_link
      dl.validate_scheme!("a")
    end
    it "accepts a 64-character scheme" do
      dl = deep_link
      dl.validate_scheme!("a" * 64)
    end
    it "raises for an empty scheme" do
      dl = deep_link
      expect_raises(CrystKit::Core::ValidationError, /cannot be empty/) do
        dl.validate_scheme!("")
      end
    end
    it "raises for a scheme exceeding 64 characters" do
      dl = deep_link
      expect_raises(CrystKit::Core::ValidationError, /exceeds maximum length/) do
        dl.validate_scheme!("a" * 65)
      end
    end
    it "raises for a scheme with hyphens" do
      dl = deep_link
      expect_raises(CrystKit::Core::ValidationError, /invalid/) do
        dl.validate_scheme!("my-app")
      end
    end
    it "raises for a scheme with dots" do
      dl = deep_link
      expect_raises(CrystKit::Core::ValidationError, /invalid/) do
        dl.validate_scheme!("my.app")
      end
    end
    it "raises for a scheme with spaces" do
      dl = deep_link
      expect_raises(CrystKit::Core::ValidationError, /invalid/) do
        dl.validate_scheme!("my app")
      end
    end
    it "raises for a scheme with special characters" do
      dl = deep_link
      expect_raises(CrystKit::Core::ValidationError, /invalid/) do
        dl.validate_scheme!("my_app!")
      end
    end
    it "raises for a scheme with underscores" do
      dl = deep_link
      expect_raises(CrystKit::Core::ValidationError, /invalid/) do
        dl.validate_scheme!("my_app")
      end
    end
  end
  describe "#unregister_scheme" do
    it "unregisters a registered scheme" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.unregister_scheme("myapp")
      dl.registered?("myapp").should be_false
    end
    it "is a no-op for an unregistered scheme" do
      dl = deep_link
      dl.unregister_scheme("nonexistent")
    end
    it "unregisters all schemes" do
      dl = deep_link
      dl.register_scheme("app1")
      dl.register_scheme("app2")
      dl.unregister_all
      dl.registered_schemes.should be_empty
    end
  end
  describe "#parse_url" do
    it "parses a simple deep link URL" do
      dl = deep_link
      result = dl.parse_url("myapp://open")
      result.scheme.should eq("myapp")
      result.host.should eq("open")
    end
    it "parses a URL with path" do
      dl = deep_link
      result = dl.parse_url("myapp://action/details")
      result.scheme.should eq("myapp")
      result.path.should eq("/details")
    end
    it "parses query parameters" do
      dl = deep_link
      result = dl.parse_url("myapp://open?id=123&name=test")
      result.query_params["id"].should eq("123")
      result.query_params["name"].should eq("test")
    end
    it "parses URL-encoded query parameters" do
      dl = deep_link
      result = dl.parse_url("myapp://open?name=hello+world")
      result.query_params["name"].should eq("hello world")
    end
    it "returns empty query params when none present" do
      dl = deep_link
      result = dl.parse_url("myapp://open")
      result.query_params.should be_empty
    end
    it "preserves the raw URL" do
      dl = deep_link
      url = "myapp://open?id=42"
      result = dl.parse_url(url)
      result.raw_url.should eq(url)
    end
    it "raises for a URL without a scheme" do
      dl = deep_link
      expect_raises(CrystKit::Core::ValidationError, /missing scheme|Invalid deep link/) do
        dl.parse_url("//open?id=1")
      end
    end
  end
  describe "#handle_url" do
    it "invokes on_open handlers for registered schemes" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.mark_started
      received = [] of CrystKit::Features::DeepLinkURL
      dl.on_open { |url| received << url }
      dl.handle_url("myapp://open?id=1")
      received.size.should eq(1)
      received[0].scheme.should eq("myapp")
      received[0].query_params["id"].should eq("1")
    end
    it "invokes multiple on_open handlers" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.mark_started
      count = 0
      dl.on_open { |_| count += 1 }
      dl.on_open { |_| count += 1 }
      dl.handle_url("myapp://open")
      count.should eq(2)
    end
    it "does not invoke handlers for unregistered schemes" do
      dl = deep_link
      dl.mark_started
      invoked = false
      dl.on_open { |_| invoked = true }
      dl.handle_url("unknown://open")
      invoked.should be_false
    end
    it "continues calling handlers even if one raises" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.mark_started
      second_called = false
      dl.on_open { |_| raise "handler error" }
      dl.on_open { |_| second_called = true }
      dl.handle_url("myapp://open")
      second_called.should be_true
    end
  end
  describe "#registered_schemes" do
    it "returns all registered schemes" do
      dl = deep_link
      dl.register_scheme("app1")
      dl.register_scheme("app2")
      dl.register_scheme("app3")
      dl.registered_schemes.size.should eq(3)
    end
  end
  describe "startup URL queuing" do
    it "queues URLs received before mark_started" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.handle_url("myapp://open?phase=startup")
      dl.pending_startup_urls.should contain("myapp://open?phase=startup")
    end
    it "does not invoke handlers for queued startup URLs" do
      dl = deep_link
      dl.register_scheme("myapp")
      invoked = false
      dl.on_open { |_| invoked = true }
      dl.handle_url("myapp://open")
      invoked.should be_false
    end
    it "flushes queued URLs when mark_started is called" do
      dl = deep_link
      dl.register_scheme("myapp")
      received = [] of CrystKit::Features::DeepLinkURL
      dl.on_open { |url| received << url }
      dl.handle_url("myapp://open?id=1")
      dl.handle_url("myapp://open?id=2")
      received.should be_empty
      dl.mark_started
      received.size.should eq(2)
      received.map(&.query_params["id"]).should contain("1")
      received.map(&.query_params["id"]).should contain("2")
    end
    it "clears the startup queue after flushing" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.handle_url("myapp://open")
      dl.mark_started
      dl.pending_startup_urls.should be_empty
    end
    it "handles URLs immediately after mark_started" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.mark_started
      received = [] of CrystKit::Features::DeepLinkURL
      dl.on_open { |url| received << url }
      dl.handle_url("myapp://open?id=live")
      received.size.should eq(1)
      received[0].query_params["id"].should eq("live")
    end
    it "started? returns true after mark_started" do
      dl = deep_link
      dl.mark_started
      dl.started?.should be_true
    end
  end
  describe "#on_foreground" do
    it "invokes the foreground handler when a deep link is activated" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.mark_started
      foreground_called = false
      dl.on_foreground { foreground_called = true }
      dl.handle_url("myapp://open")
      foreground_called.should be_true
    end
    it "invokes the foreground handler before on_open handlers" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.mark_started
      order = [] of String
      dl.on_foreground { order << "foreground" }
      dl.on_open { |_| order << "open" }
      dl.handle_url("myapp://open")
      order.first.should eq("foreground")
    end
    it "does not invoke the foreground handler for unregistered schemes" do
      dl = deep_link
      dl.mark_started
      foreground_called = false
      dl.on_foreground { foreground_called = true }
      dl.handle_url("unknown://open")
      foreground_called.should be_false
    end
    it "continues dispatching even if the foreground handler raises" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.mark_started
      open_called = false
      dl.on_foreground { raise "foreground error" }
      dl.on_open { |_| open_called = true }
      dl.handle_url("myapp://open")
      open_called.should be_true
    end
  end
  describe "#attach_router" do
    it "emits a deep-link event on the bus when a URL is handled" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.mark_started
      router = CrystKit::IPC::Router.new
      dl.attach_router(router)
      received_payloads = [] of JSON::Any
      router.subscribe_event("deep-link", ->(payload : JSON::Any) { received_payloads << payload })
      dl.handle_url("myapp://open?id=99")
      received_payloads.size.should eq(1)
      received_payloads[0]["url"].as_s.should eq("myapp://open?id=99")
      received_payloads[0]["scheme"].as_s.should eq("myapp")
    end
    it "includes query parameters in the emitted event payload" do
      dl = deep_link
      dl.register_scheme("myapp")
      dl.mark_started
      router = CrystKit::IPC::Router.new
      dl.attach_router(router)
      received_payloads = [] of JSON::Any
      router.subscribe_event("deep-link", ->(payload : JSON::Any) { received_payloads << payload })
      dl.handle_url("myapp://open?foo=bar&baz=qux")
      received_payloads[0]["params"]["foo"].as_s.should eq("bar")
      received_payloads[0]["params"]["baz"].as_s.should eq("qux")
    end
    it "does not emit an event for unregistered schemes" do
      dl = deep_link
      dl.mark_started
      router = CrystKit::IPC::Router.new
      dl.attach_router(router)
      emitted = false
      router.subscribe_event("deep-link", ->(_payload : JSON::Any) { emitted = true })
      dl.handle_url("unknown://open")
      emitted.should be_false
    end
    it "emits events for startup-queued URLs after mark_started" do
      dl = deep_link
      dl.register_scheme("myapp")
      router = CrystKit::IPC::Router.new
      dl.attach_router(router)
      received_payloads = [] of JSON::Any
      router.subscribe_event("deep-link", ->(payload : JSON::Any) { received_payloads << payload })
      dl.handle_url("myapp://open?startup=true")
      received_payloads.should be_empty
      dl.mark_started
      received_payloads.size.should eq(1)
      received_payloads[0]["params"]["startup"].as_s.should eq("true")
    end
  end
end
