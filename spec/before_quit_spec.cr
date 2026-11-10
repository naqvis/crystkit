require "./spec_helper"
describe CrystKit::Future do
  it "returns nil before resolution and the value after" do
    future = CrystKit::Future(Bool).new
    future.resolved?.should be_false
    future.resolve(true)
    future.resolved?.should be_true
    future.get?.should be_true
  end
  it "ignores subsequent resolves after the first" do
    future = CrystKit::Future(Int32).new
    future.resolve(1)
    future.resolve(2)
    future.get?.should eq(1)
  end
  it "returns the cached value on repeated gets without blocking" do
    future = CrystKit::Future(String).new
    future.resolve("ok")
    future.get?.should eq("ok")
    future.get?.should eq("ok")
  end
  it "returns nil when the wait times out before resolution" do
    future = CrystKit::Future(Bool).new
    start = Time.instant
    future.get?(50.milliseconds).should be_nil
    (Time.instant - start).should be >= 40.milliseconds
  end
  it "wakes a waiting getter when resolve is called from another fiber" do
    future = CrystKit::Future(Bool).new
    spawn do
      sleep 20.milliseconds
      future.resolve(true)
    end
    future.get?(2.seconds).should be_true
  end
  it "wakes every getter that was waiting concurrently" do
    future = CrystKit::Future(Int32).new
    ready = Channel(Bool).new(8)
    results = Channel(Int32?).new(8)

    8.times do
      spawn do
        ready.send(true)
        results.send(future.get?(2.seconds))
      end
    end
    8.times { ready.receive }
    10.times { Fiber.yield }

    future.resolve(42)
    Array.new(8) { results.receive }.should eq(Array.new(8, 42))
  end
end
describe CrystKit::App, "#on_before_quit" do
  it "allows quit when no interceptor is registered" do
    app = make_app
    shut_down = false
    app.on_shutdown { shut_down = true }
    app.runtime.lifecycle.running = true
    app.quit
    shut_down.should be_true
  end
  it "allows quit when a synchronous interceptor returns true" do
    app = make_app
    consulted = false
    app.on_before_quit { consulted = true; true }
    shut_down = false
    app.on_shutdown { shut_down = true }
    app.runtime.lifecycle.running = true
    app.quit
    consulted.should be_true
    shut_down.should be_true
  end
  it "cancels quit when a synchronous interceptor returns false" do
    app = make_app
    consulted = false
    app.on_before_quit { consulted = true; false }
    shut_down = false
    app.on_shutdown { shut_down = true }
    app.runtime.lifecycle.running = true
    app.quit
    consulted.should be_true
    shut_down.should be_false
    app.running?.should be_true
  end
  it "awaits a Future(Bool) that resolves true, then proceeds" do
    app = make_app
    future = CrystKit::Future(Bool).new
    app.on_before_quit { future }
    shut_down = false
    app.on_shutdown { shut_down = true }
    app.runtime.lifecycle.running = true
    spawn { sleep 20.milliseconds; future.resolve(true) }
    app.quit
    shut_down.should be_true
    future.resolved?.should be_true
  end
  it "cancels quit when a Future(Bool) resolves false" do
    app = make_app
    future = CrystKit::Future(Bool).new
    app.on_before_quit { future }
    shut_down = false
    app.on_shutdown { shut_down = true }
    app.runtime.lifecycle.running = true
    spawn { sleep 20.milliseconds; future.resolve(false) }
    app.quit
    shut_down.should be_false
    app.running?.should be_true
  end
  it "cancels quit when the future does not resolve before the timeout" do
    app = make_app
    future = CrystKit::Future(Bool).new
    app.on_before_quit { future }
    app.before_quit_timeout = 50.milliseconds
    app.before_quit_timeout.should eq(50.milliseconds)
    shut_down = false
    app.on_shutdown { shut_down = true }
    app.runtime.lifecycle.running = true
    start = Time.instant
    app.quit
    (Time.instant - start).should be >= 40.milliseconds
    shut_down.should be_false
    app.running?.should be_true
    future.resolved?.should be_false
  end
  it "does not consult the interceptor when the app is not running" do
    app = make_app
    consulted = false
    app.on_before_quit { consulted = true; false }
    shut_down = false
    app.on_shutdown { shut_down = true }
    app.quit
    consulted.should be_false
    shut_down.should be_true
  end
end

private def make_app : CrystKit::App
  dir = File.tempname("before_quit_spec")
  Dir.mkdir_p(dir)
  config = CrystKit::AppConfig.new(
    identifier: "test.before_quit.#{Random.rand(100_000)}",
    storage_dir: Path[dir],
  )
  CrystKit::App.new(config)
end
