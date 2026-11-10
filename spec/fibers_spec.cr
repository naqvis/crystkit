require "./spec_helper"

describe CrystKit::Core::Fibers do
  it "keeps the default GUI context on its original system thread across blocking syscalls" do
    original_thread = Thread.current

    Fiber::ExecutionContext::Scheduler.current.syscall do
      Thread.sleep 50.milliseconds
    end

    Thread.current.same?(original_thread).should be_true
  end
end
