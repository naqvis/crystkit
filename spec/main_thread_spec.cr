require "./spec_helper"
require "../src/crystkit"
describe CrystKit::Core::MainThread do
  describe ".on_main?" do
    it "is true when no app is constructed (we are on the main thread)" do
      CrystKit::Core::MainThread.on_main?.should be_true
    end
    it "is true after capture_main_fiber on the current fiber" do
      CrystKit::Core::MainThread.capture_main_fiber
      CrystKit::Core::MainThread.on_main?.should be_true
    ensure
      CrystKit::Core::MainThread.clear
    end
    it "is false on a different fiber after capture" do
      CrystKit::Core::MainThread.capture_main_fiber
      result = Channel(Bool).new(1)
      spawn do
        result.send(CrystKit::Core::MainThread.on_main?)
      end
      result.receive.should be_false
    ensure
      CrystKit::Core::MainThread.clear
    end
  end
  describe ".dispatch_sync" do
    it "runs the block inline when on_main? is true (no channel)" do
      CrystKit::Core::MainThread.capture_main_fiber
      result = CrystKit::Core::MainThread.dispatch_sync { 42 }
      result.should eq(42)
    ensure
      CrystKit::Core::MainThread.clear
    end
    it "dispatches to main and returns the result from a fiber" do
      CrystKit::Core::MainThread.capture_main_fiber
      main_fiber = Fiber.current
      CrystKit::Core::MainThread.register(main_fiber, ->(block : Proc(Nil)) { block.call })
      result_chan = Channel(Int32).new(1)
      spawn do
        val = CrystKit::Core::MainThread.dispatch_sync { 99 }
        result_chan.send(val)
      end
      result_chan.receive.should eq(99)
    ensure
      CrystKit::Core::MainThread.clear
    end
    it "raises MAINTHREAD_NOT_REGISTERED when called off-main with no dispatch registered" do
      CrystKit::Core::MainThread.capture_main_fiber
      chan = Channel(Exception?).new(1)
      spawn do
        begin
          CrystKit::Core::MainThread.dispatch_sync { 1 }
          chan.send(nil)
        rescue ex : CrystKit::Core::Error
          chan.send(ex)
        rescue ex
          chan.send(ex)
        end
      end
      sleep 0.01.seconds
      CrystKit::Core::MainThread.clear
      err = chan.receive
      err.should be_a(CrystKit::Core::Error)
      err.as(CrystKit::Core::Error).code.should eq("MAINTHREAD_NOT_REGISTERED")
    ensure
      CrystKit::Core::MainThread.clear
    end
    it "propagates exceptions from the dispatched block" do
      CrystKit::Core::MainThread.capture_main_fiber
      main_fiber = Fiber.current
      CrystKit::Core::MainThread.register(main_fiber, ->(block : Proc(Nil)) { block.call })
      chan = Channel(Exception?).new(1)
      spawn do
        begin
          CrystKit::Core::MainThread.dispatch_sync { raise "boom" }
          chan.send(nil)
        rescue ex : CrystKit::Core::Error
          chan.send(ex)
        rescue ex
          chan.send(ex)
        end
      end
      err = chan.receive
      err.should be_a(CrystKit::Core::Error)
      err.as(CrystKit::Core::Error).code.should eq("MAINTHREAD_BLOCK_ERROR")
    ensure
      CrystKit::Core::MainThread.clear
    end
    it "fails with WINDOW_DESTROYED when fail_all_pending is called" do
      CrystKit::Core::MainThread.capture_main_fiber
      main_fiber = Fiber.current
      CrystKit::Core::MainThread.register(main_fiber, ->(_block : Proc(Nil)) { })
      chan = Channel(Exception?).new(1)
      spawn do
        begin
          CrystKit::Core::MainThread.dispatch_sync { sleep 60.seconds }
          chan.send(nil)
        rescue ex : CrystKit::Core::Error
          chan.send(ex)
        rescue ex
          chan.send(ex)
        end
      end
      10.times { Fiber.yield; sleep 5.milliseconds }
      CrystKit::Core::MainThread.fail_all_pending(
        "Window destroyed",
        "WINDOW_DESTROYED",
      )
      err = chan.receive
      err.should be_a(CrystKit::Core::Error)
      err.as(CrystKit::Core::Error).code.should eq("WINDOW_DESTROYED")
    ensure
      CrystKit::Core::MainThread.clear
    end
    it "wakes in-flight dispatches when MainThread is cleared" do
      CrystKit::Core::MainThread.capture_main_fiber
      main_fiber = Fiber.current
      queued = Channel(Bool).new(1)
      CrystKit::Core::MainThread.register(main_fiber, ->(_block : Proc(Nil)) { queued.send(true) })
      result = Channel(Exception?).new(1)
      spawn do
        CrystKit::Core::MainThread.dispatch_sync { 1 }
        result.send(nil)
      rescue ex
        result.send(ex)
      end
      queued.receive

      CrystKit::Core::MainThread.clear
      error = result.receive
      error.should be_a(CrystKit::Core::Error)
      error.as(CrystKit::Core::Error).code.should eq("MAINTHREAD_NOT_REGISTERED")
    ensure
      CrystKit::Core::MainThread.clear
    end
  end
  describe ".register and .clear" do
    it "clear is safe to call repeatedly" do
      CrystKit::Core::MainThread.clear
      CrystKit::Core::MainThread.clear
    end
  end
  describe ".dispatch (fire-and-forget)" do
    it "runs the block inline when on_main?" do
      CrystKit::Core::MainThread.capture_main_fiber
      executed = false
      CrystKit::Core::MainThread.dispatch { executed = true }
      executed.should be_true
    ensure
      CrystKit::Core::MainThread.clear
    end
    it "queues the block via the dispatch closure when off main" do
      CrystKit::Core::MainThread.capture_main_fiber
      main_fiber = Fiber.current
      CrystKit::Core::MainThread.register(main_fiber, ->(block : Proc(Nil)) { block.call })
      done = Channel(Bool).new(1)
      spawn do
        CrystKit::Core::MainThread.dispatch { done.send(true) }
      end
      done.receive.should be_true
    ensure
      CrystKit::Core::MainThread.clear
    end
  end
end
