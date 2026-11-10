require "../features/idle_monitor"

module CrystKit::Test
  class FakeIdleProvider < Features::IdleMonitor::Provider
    alias Change = Features::IdleMonitor::Change

    property duration : Time::Span
    getter? running = false

    @changed : Proc(Change, Nil)?

    def initialize(@duration : Time::Span = 0.seconds)
    end

    def start(threshold : Time::Span, interval : Time::Span, &changed : Change ->) : Nil
      @running = true
      @changed = changed
    end

    def stop : Nil
      @running = false
      @changed = nil
    end

    def change(idle : Bool, seconds : Int32) : Nil
      @duration = seconds.seconds
      @changed.try(&.call(Change.new(idle, seconds)))
    end
  end
end
