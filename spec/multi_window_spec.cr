require "./spec_helper"
require "../src/app/app"
require "../src/core/native_window"
describe "Multi-window" do
  it "creates 5 independent windows and registers them" do
    SpecHelpers.with_fake_window_app do |app|
      windows = (1..5).map { |i|
        app.window(
          title: "Window #{i}",
          label: "w#{i}",
          width: 400, height: 300,
        )
      }
      app.windows.size.should eq(5)
      windows.each_with_index do |w, i|
        w.title.should eq("Window #{i + 1}")
        w.label.should eq("w#{i + 1}")
      end
      app.shutdown
    end
  end
  it "creates windows with WindowOptions preload_scripts and CSP" do
    SpecHelpers.with_fake_window_app do |app|
      opts = CrystKit::Core::WindowOptions.new(
        title: "Options Window",
        label: "opts_win",
        width: 400, height: 300,
        preload_scripts: ["window.__PRELOADED__ = true"],
        csp: "default-src 'self'",
      )
      w = app.window(options: opts)
      w.label.should eq("opts_win")
      w.title.should eq("Options Window")
      app.shutdown
    end
  end
  it "close prevention works independently per window" do
    SpecHelpers.with_fake_window_app do |app|
      w_allow = app.window(title: "Allow", label: "allow", width: 400, height: 300)
      w_prevent = app.window(title: "Prevent", label: "prevent", width: 400, height: 300)
      w_allow.on_close { true }
      w_prevent.on_close { false }
      w_allow.native.handle_close_request.should be_true
      w_prevent.native.handle_close_request.should be_false
      app.shutdown
    end
  end
  it "close lifecycle events fire independently per window" do
    SpecHelpers.with_fake_window_app do |app|
      w1 = app.window(title: "W1", label: "w1", width: 400, height: 300)
      w2 = app.window(title: "W2", label: "w2", width: 400, height: 300)
      w1_close = false
      w2_close = false
      w1.on("close") { w1_close = true }
      w2.on("close") { w2_close = true }
      w1.on_close { true }
      w1.native.handle_close_request
      w1_close.should be_true
      w2_close.should be_false
      w2.on_close { false }
      w2.native.handle_close_request
      w2_close.should be_false
      app.shutdown
    end
  end
  it "window registry supports label and id lookups with multiple windows" do
    SpecHelpers.with_fake_window_app do |app|
      w1 = app.window(title: "Alpha", label: "alpha", width: 400, height: 300)
      w2 = app.window(title: "Beta", label: "beta", width: 400, height: 300)
      app.window_registry.find?("alpha").should eq(w1)
      app.window_registry.find?("beta").should eq(w2)
      app.window_registry.find?(w1.id).should eq(w1)
      app.window_registry.primary.should eq(w1)
      app.shutdown
    end
  end
  it "creates modal child window via parent_label" do
    SpecHelpers.with_fake_window_app do |app|
      parent = app.window(title: "Parent", label: "parent", width: 600, height: 400)
      child_opts = CrystKit::Core::WindowOptions.new(
        title: "Child",
        label: "child",
        width: 300, height: 200,
        modal: true,
      )
      child = app.window(options: child_opts, parent_label: "parent")
      child.label.should eq("child")
      app.windows.size.should eq(2)
      child.native.child?.should be_true
      child.native.parent.should eq(parent.native)
      app.shutdown
    end
  end
  it "emit runs without error when app has windows" do
    SpecHelpers.with_fake_window_app do |app|
      _w1 = app.window(title: "Emitter", label: "emitter", width: 400, height: 300)
      received = [] of String
      app.on("test:event") { |payload| received << payload["val"].as_s }
      app.emit("test:event", JSON.parse(%({"val":"ok"})))
      received.should eq(["ok"])
      app.shutdown
    end
  end
end
