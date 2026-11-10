require "../features/power_monitor"

module CrystKit::Test
  class FakePowerProvider < Features::PowerMonitor::Provider
    alias BatteryInfo = Features::PowerMonitor::BatteryInfo

    property current_info : BatteryInfo?
    getter? running = false

    @changed : Proc(BatteryInfo?, Nil)?

    def initialize(@current_info : BatteryInfo? = nil)
    end

    def current : BatteryInfo?
      @current_info
    end

    def start(interval : Time::Span, &changed : BatteryInfo? ->) : Nil
      @running = true
      @changed = changed
    end

    def stop : Nil
      @running = false
      @changed = nil
    end

    def change(info : BatteryInfo?) : Nil
      @current_info = info
      @changed.try(&.call(info))
    end
  end
end
