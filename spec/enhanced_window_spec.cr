require "./spec_helper"
require "../src/core/native_window"
describe CrystKit::Core::WindowOptions do
  it "defaults preload_scripts to empty array" do
    opts = CrystKit::Core::WindowOptions.new
    opts.preload_scripts.should eq([] of String)
  end
  it "defaults csp to nil" do
    opts = CrystKit::Core::WindowOptions.new
    opts.csp.should be_nil
  end
  it "accepts preload_scripts in constructor" do
    opts = CrystKit::Core::WindowOptions.new(preload_scripts: ["alert('hi')"])
    opts.preload_scripts.should eq(["alert('hi')"])
  end
  it "accepts csp in constructor" do
    opts = CrystKit::Core::WindowOptions.new(csp: "default-src 'self'")
    opts.csp.should eq("default-src 'self'")
  end
  it "round-trips all WindowOptions properties through positional args" do
    opts = CrystKit::Core::WindowOptions.new(
      width: 1024, height: 768,
      hint: ::Webview::SizeHints::NONE,
      title: "Test", url: nil,
      debug: false, label: nil,
      modal: false, always_on_top: false,
      frameless: false, transparent: false,
      opacity: 1.0, visible: true,
      minimize_to_tray: true, fullscreen: false,
      x: 100, y: 200,
      preload_scripts: ["script1", "script2"],
      csp: "default-src 'none'",
    )
    opts.preload_scripts.should eq(["script1", "script2"])
    opts.csp.should eq("default-src 'none'")
    opts.minimize_to_tray?.should be_true
    opts.fullscreen?.should be_false
    opts.x.should eq(100)
    opts.y.should eq(200)
  end
  it "defaults minimize_to_tray to false" do
    opts = CrystKit::Core::WindowOptions.new
    opts.minimize_to_tray?.should be_false
  end
  it "defaults fullscreen to false" do
    opts = CrystKit::Core::WindowOptions.new
    opts.fullscreen?.should be_false
  end
  it "defaults x and y to nil" do
    opts = CrystKit::Core::WindowOptions.new
    opts.x.should be_nil
    opts.y.should be_nil
  end
end
describe CrystKit::Core::EnhancedWindow do
  describe "frameless mode" do
    it "defaults to non-frameless" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.frameless?.should be_false
      wv.destroy
    end
    it "can be set to frameless" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.frameless = true
      wv.frameless?.should be_true
      wv.destroy
    end
    it "can be toggled back to framed" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.frameless = true
      wv.frameless = false
      wv.frameless?.should be_false
      wv.destroy
    end
  end
  describe "transparency" do
    it "defaults to non-transparent" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.transparent?.should be_false
      wv.destroy
    end
    it "can be set to transparent" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.transparent = true
      wv.transparent?.should be_true
      wv.destroy
    end
    it "defaults opacity to 1.0" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.opacity.should eq(1.0)
      wv.destroy
    end
    it "raises ArgumentError for opacity below 0.0" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      expect_raises(ArgumentError, /Opacity must be between/) do
        wv.opacity = -0.1
      end
      wv.destroy
    end
    it "raises ArgumentError for opacity above 1.0" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      expect_raises(ArgumentError, /Opacity must be between/) do
        wv.opacity = 1.1
      end
      wv.destroy
    end
  end
  describe "focus/blur events" do
    it "starts unfocused" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.focused?.should be_false
      wv.destroy
    end
    it "emit_focus sets focused? to true and fires on_focus handler" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      fired = false
      wv.on_focus { fired = true }
      wv.emit_focus
      wv.focused?.should be_true
      fired.should be_true
      wv.destroy
    end
    it "emit_blur sets focused? to false and fires on_blur handler" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.emit_focus
      blurred = false
      wv.on_blur { blurred = true }
      wv.emit_blur
      wv.focused?.should be_false
      blurred.should be_true
      wv.destroy
    end
  end
  describe "move/resize events" do
    it "emit_move fires on_move handler with coordinates" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      received_x = 0
      received_y = 0
      wv.on_move { |x, y| received_x = x; received_y = y }
      wv.emit_move(100, 200)
      received_x.should eq(100)
      received_y.should eq(200)
      wv.destroy
    end
    it "emit_resize fires on_resize handler with dimensions" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      received_w = 0
      received_h = 0
      wv.on_resize { |w, h| received_w = w; received_h = h }
      wv.emit_resize(1280, 720)
      received_w.should eq(1280)
      received_h.should eq(720)
      wv.destroy
    end
  end
  describe "minimize/maximize/restore events" do
    it "minimize sets minimized? true and fires handler" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      fired = false
      wv.on_minimize { fired = true }
      wv.minimize
      wv.minimized?.should be_true
      wv.maximized?.should be_false
      fired.should be_true
      wv.destroy
    end
    it "maximize sets maximized? true and fires handler" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      fired = false
      wv.on_maximize { fired = true }
      wv.maximize
      wv.maximized?.should be_true
      wv.minimized?.should be_false
      fired.should be_true
      wv.destroy
    end
    it "restore clears both flags and fires handler" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.minimize
      fired = false
      wv.on_restore { fired = true }
      wv.restore
      wv.minimized?.should be_false
      wv.maximized?.should be_false
      fired.should be_true
      wv.destroy
    end
    it "minimize clears maximized flag" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.maximize
      wv.minimize
      wv.maximized?.should be_false
      wv.minimized?.should be_true
      wv.destroy
    end
    it "maximize clears minimized flag" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.minimize
      wv.maximize
      wv.minimized?.should be_false
      wv.maximized?.should be_true
      wv.destroy
    end
  end
  describe "fullscreen mode" do
    it "defaults to non-fullscreen" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.fullscreen?.should be_false
      wv.destroy
    end
    it "can be set to fullscreen" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.fullscreen = true
      wv.fullscreen?.should be_true
      wv.destroy
    end
  end
  describe "always-on-top" do
    it "defaults to not always-on-top" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.always_on_top?.should be_false
      wv.destroy
    end
    it "can be set to always-on-top" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.always_on_top = true
      wv.always_on_top?.should be_true
      wv.destroy
    end
  end
  describe "visibility control" do
    it "starts visible" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.visible?.should be_true
      wv.destroy
    end
    it "hide sets visible? to false" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.hide
      wv.visible?.should be_false
      wv.destroy
    end
    it "show restores visible? to true" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.hide
      wv.show
      wv.visible?.should be_true
      wv.destroy
    end
  end
  describe "window label" do
    it "stores the label" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", "main")
      wv.label.should eq("main")
      wv.destroy
    end
    it "label defaults to nil" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.label.should be_nil
      wv.destroy
    end
  end
  describe "modal windows" do
    it "defaults to non-modal" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.modal?.should be_false
      wv.destroy
    end
    it "can be set to modal" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.modal = true
      wv.modal?.should be_true
      wv.destroy
    end
  end
  describe "parent-child relationships" do
    it "starts with no parent" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.parent.should be_nil
      wv.child?.should be_false
      wv.destroy
    end
    it "starts with no children" do
      wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
      wv.children.should be_empty
      wv.destroy
    end
    it "create_child sets parent reference on child" do
      parent = CrystKit::Core::EnhancedWindow.fake(false, "Parent", "parent")
      opts = CrystKit::Core::WindowOptions.new(title: "Child", label: "child")
      child = parent.create_child(opts)
      child.parent.should eq(parent)
      child.child?.should be_true
      child.destroy
      parent.destroy
    end
    it "create_child propagates frameless option" do
      parent = CrystKit::Core::EnhancedWindow.fake(false, "Parent", "parent")
      opts = CrystKit::Core::WindowOptions.new(title: "Child", label: "child", frameless: true)
      child = parent.create_child(opts)
      child.frameless?.should be_true
      child.destroy
      parent.destroy
    end
    it "create_child propagates opacity option" do
      parent = CrystKit::Core::EnhancedWindow.fake(false, "Parent", "parent")
      opts = CrystKit::Core::WindowOptions.new(title: "Child", label: "child", opacity: 0.75)
      child = parent.create_child(opts)
      child.opacity.should eq(0.75)
      child.destroy
      parent.destroy
    end
  end
end
describe CrystKit::Core::EnhancedWindow, "close prevention" do
  it "handle_close_request returns true by default" do
    wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
    wv.handle_close_request.should be_true
    wv.destroy
  end
  it "on_close returning false prevents close" do
    wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
    wv.on_close { false }
    wv.handle_close_request.should be_false
    wv.destroy
  end
  it "on_close returning true allows close" do
    wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
    wv.on_close { true }
    wv.handle_close_request.should be_true
    wv.destroy
  end
  it "handle_close_request invokes the on_close handler" do
    wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", nil)
    called = false
    wv.on_close { called = true; true }
    wv.handle_close_request
    called.should be_true
    wv.destroy
  end
  it "fake window has a null native handle and is not registered" do
    wv = CrystKit::Core::EnhancedWindow.fake(false, "Test", "lookup_test")
    wv.window.should eq(Pointer(Void).null)
    CrystKit::Core::EnhancedWindow.lookup(Pointer(Void).null).should be_nil
  end
end
describe CrystKit::Core::Window do
  it "registers labels for ordinary windows" do
    SpecHelpers.with_fake_window_app do |app|
      window = app.window(title: "Main", label: "main", width: 640, height: 480)
      window.should be(app.window_registry.find?("main"))
      window.label.should eq("main")
      app.shutdown
    end
  end
  it "is the registered operational surface for all windows" do
    SpecHelpers.with_fake_window_app do |app|
      window = app.window(title: "Main", label: "main", width: 640, height: 480)
      window.should be(app.window_registry.find?("main"))
      window.title.should eq("Main")
      window.width.should eq(640)
      window.height.should eq(480)
      window.visible?.should be_true
      window.native.should_not be_nil
      destroyed = false
      window.on("destroy") { destroyed = true }
      app.shutdown
      destroyed.should be_true
    end
  end
  describe "close lifecycle" do
    it "fires 'close' lifecycle event when handle_close_request returns true" do
      SpecHelpers.with_fake_window_app do |app|
        window = app.window(title: "Test", label: "close_test", width: 400, height: 300)
        close_fired = false
        window.on("close") { close_fired = true }
        window.on_close { true }
        window.native.handle_close_request
        close_fired.should be_true
        app.shutdown
      end
    end
    it "does not fire 'close' lifecycle event when handle_close_request returns false" do
      SpecHelpers.with_fake_window_app do |app|
        window = app.window(title: "Test", label: "close_prevent", width: 400, height: 300)
        close_fired = false
        window.on("close") { close_fired = true }
        window.on_close { false }
        window.native.handle_close_request
        close_fired.should be_false
        app.shutdown
      end
    end
    it "Core::Window#on_close delegates to EnhancedWindow platform hooks" do
      SpecHelpers.with_fake_window_app do |app|
        window = app.window(title: "Test", label: "close_delegate", width: 400, height: 300)
        handler_called = false
        window.on_close { handler_called = true; true }
        window.native.handle_close_request
        handler_called.should be_true
        app.shutdown
      end
    end
  end
end
