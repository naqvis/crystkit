require "./spec_helper"
require "../src/features/devtools"

private def make_devtools_enabled
  config = CrystKit::Features::DevToolsConfig.new(
    enabled: true,
    forward_console: true,
    forward_js_errors: true,
  )
  CrystKit::Features::DevTools.new(config)
end

private def make_devtools_disabled
  config = CrystKit::Features::DevToolsConfig.new(enabled: false)
  CrystKit::Features::DevTools.new(config)
end

describe CrystKit::Features::DevTools do
  it "starts in closed state" do
    dt = make_devtools_enabled
    dt.open?.should be_false
  end
  it "reports enabled when config has enabled: true" do
    dt = make_devtools_enabled
    dt.enabled?.should be_true
  end
  it "reports disabled when config has enabled: false" do
    dt = make_devtools_disabled
    dt.enabled?.should be_false
  end
  it "does not open when disabled (production mode)" do
    dt = make_devtools_disabled
    dt.open(Pointer(Void).null)
    dt.open?.should be_false
  end
  it "tracks open state after open() with null pointer on enabled config" do
    dt = make_devtools_enabled
    dt.open(Pointer(Void).null)
    dt.open?.should be_true
  end
  it "tracks closed state after close()" do
    dt = make_devtools_enabled
    dt.open(Pointer(Void).null)
    dt.close(Pointer(Void).null)
    dt.open?.should be_false
  end
  it "toggle opens when closed" do
    dt = make_devtools_enabled
    dt.toggle(Pointer(Void).null)
    dt.open?.should be_true
  end
  it "toggle closes when open" do
    dt = make_devtools_enabled
    dt.open(Pointer(Void).null)
    dt.toggle(Pointer(Void).null)
    dt.open?.should be_false
  end
  it "open is idempotent — calling open twice stays open" do
    dt = make_devtools_enabled
    dt.open(Pointer(Void).null)
    dt.open(Pointer(Void).null)
    dt.open?.should be_true
  end
  it "close is idempotent — calling close when already closed is safe" do
    dt = make_devtools_enabled
    dt.close(Pointer(Void).null)
    dt.open?.should be_false
  end
  it "default dock mode is Bottom" do
    dt = make_devtools_enabled
    dt.config.dock_mode.should eq(CrystKit::Features::DevToolsDockMode::Bottom)
  end
  it "set_dock_mode updates the config" do
    dt = make_devtools_enabled
    dt.set_dock_mode(CrystKit::Features::DevToolsDockMode::Right, Pointer(Void).null)
    dt.config.dock_mode.should eq(CrystKit::Features::DevToolsDockMode::Right)
  end
  it "set_dock_mode to Undocked is accepted" do
    dt = make_devtools_enabled
    dt.set_dock_mode(CrystKit::Features::DevToolsDockMode::Undocked, Pointer(Void).null)
    dt.config.dock_mode.should eq(CrystKit::Features::DevToolsDockMode::Undocked)
  end
  it "forwards console messages to registered handlers" do
    dt = make_devtools_enabled
    received = [] of CrystKit::Features::ConsoleMessage
    dt.on_console_message { |msg| received << msg }
    msg = CrystKit::Features::ConsoleMessage.new("log", "hello from JS", "app.js", 42)
    dt.handle_console_message(msg)
    received.size.should eq(1)
    received[0].level.should eq("log")
    received[0].text.should eq("hello from JS")
    received[0].source.should eq("app.js")
    received[0].line.should eq(42)
  end
  it "does not forward console messages when forward_console is false" do
    config = CrystKit::Features::DevToolsConfig.new(
      enabled: true,
      forward_console: false,
    )
    dt = CrystKit::Features::DevTools.new(config)
    received = [] of CrystKit::Features::ConsoleMessage
    dt.on_console_message { |msg| received << msg }
    msg = CrystKit::Features::ConsoleMessage.new("warn", "suppressed")
    dt.handle_console_message(msg)
    received.should be_empty
  end
  it "forwards console messages to multiple handlers" do
    dt = make_devtools_enabled
    count = 0
    dt.on_console_message { |_| count += 1 }
    dt.on_console_message { |_| count += 1 }
    dt.handle_console_message(CrystKit::Features::ConsoleMessage.new("error", "oops"))
    count.should eq(2)
  end
  it "isolates console handler errors — other handlers still run" do
    dt = make_devtools_enabled
    second_called = false
    dt.on_console_message { |_| raise "handler error" }
    dt.on_console_message { |_| second_called = true }
    dt.handle_console_message(CrystKit::Features::ConsoleMessage.new("log", "test"))
    second_called.should be_true
  end
  it "forwards JS errors to registered handlers" do
    dt = make_devtools_enabled
    received = [] of CrystKit::Features::JSError
    dt.on_js_error { |err| received << err }
    err = CrystKit::Features::JSError.new("TypeError: undefined", "main.js", 10, 5, "at main.js:10")
    dt.handle_js_error(err)
    received.size.should eq(1)
    received[0].message.should eq("TypeError: undefined")
    received[0].source.should eq("main.js")
    received[0].line.should eq(10)
    received[0].column.should eq(5)
    received[0].stack.should eq("at main.js:10")
  end
  it "does not forward JS errors when forward_js_errors is false" do
    config = CrystKit::Features::DevToolsConfig.new(
      enabled: true,
      forward_js_errors: false,
    )
    dt = CrystKit::Features::DevTools.new(config)
    received = [] of CrystKit::Features::JSError
    dt.on_js_error { |err| received << err }
    dt.handle_js_error(CrystKit::Features::JSError.new("suppressed"))
    received.should be_empty
  end
  it "isolates JS error handler errors — other handlers still run" do
    dt = make_devtools_enabled
    second_called = false
    dt.on_js_error { |_| raise "handler error" }
    dt.on_js_error { |_| second_called = true }
    dt.handle_js_error(CrystKit::Features::JSError.new("test error"))
    second_called.should be_true
  end
  it "fires on_open handler when dev tools are opened" do
    dt = make_devtools_enabled
    opened = false
    dt.on_open { opened = true }
    dt.open(Pointer(Void).null)
    opened.should be_true
  end
  it "fires on_close handler when dev tools are closed" do
    dt = make_devtools_enabled
    closed = false
    dt.on_close { closed = true }
    dt.open(Pointer(Void).null)
    dt.close(Pointer(Void).null)
    closed.should be_true
  end
  it "does not fire on_open when dev tools are disabled" do
    dt = make_devtools_disabled
    opened = false
    dt.on_open { opened = true }
    dt.open(Pointer(Void).null)
    opened.should be_false
  end
  it "remote_debugging? returns false when port is 0" do
    dt = make_devtools_enabled
    dt.remote_debugging?.should be_false
    dt.remote_debug_port.should eq(0)
  end
  it "remote_debugging? returns true when port is set" do
    config = CrystKit::Features::DevToolsConfig.new(
      enabled: true,
      remote_debug_port: 9222,
    )
    dt = CrystKit::Features::DevTools.new(config)
    dt.remote_debugging?.should be_true
    dt.remote_debug_port.should eq(9222)
  end
  it "build_mode returns a symbol" do
    mode = CrystKit::Features::DevTools.build_mode
    (mode == :debug || mode == :release).should be_true
  end
  it "default_config returns a DevToolsConfig" do
    cfg = CrystKit::Features::DevTools.default_config
    cfg.should be_a(CrystKit::Features::DevToolsConfig)
  end
  it "opens and closes dev tools via the window integration backend" do
    backend = CrystKit::Test::FakeWindowIntegrationBackend.new
    config = CrystKit::Features::DevToolsConfig.new(enabled: true)
    dt = CrystKit::Features::DevTools.new(config, backend)
    dt.open(Pointer(Void).null)
    dt.open?.should be_true
    backend.opened?.should be_true
    backend.last_dock_mode.should eq(CrystKit::Features::DevToolsDockMode::Bottom.value)
    dt.close(Pointer(Void).null)
    dt.open?.should be_false
    backend.closed?.should be_true
  end

  it "does not open when disabled, and ignores close when not open" do
    backend = CrystKit::Test::FakeWindowIntegrationBackend.new
    config = CrystKit::Features::DevToolsConfig.new(enabled: false)
    dt = CrystKit::Features::DevTools.new(config, backend)
    dt.open(Pointer(Void).null)
    dt.open?.should be_false
    backend.opened?.should be_false
    dt.close(Pointer(Void).null)
    backend.closed?.should be_false
  end

  it "console messages are forwarded to registered handlers" do
    config = CrystKit::Features::DevToolsConfig.new(
      enabled: true,
      forward_console: true,
    )
    dt = CrystKit::Features::DevTools.new(config)
    received = [] of CrystKit::Features::ConsoleMessage
    dt.on_console_message { |msg| received << msg }
    msg = CrystKit::Features::ConsoleMessage.new("log", "test message", "test.js", 1)
    dt.handle_console_message(msg)
    received.size.should eq(1)
    received[0].text.should eq("test message")
  end
end
