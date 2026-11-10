require "../features/cpu_monitor"

module CrystKit::Test
  class FakeCpuProvider < Features::CpuMonitor::Provider
    getter resets = 0

    def initialize(@samples : Array(Float64?) = [] of Float64?)
    end

    def sample : Float64?
      @samples.shift?
    end

    def reset : Nil
      @resets += 1
    end
  end
end
