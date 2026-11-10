require "../features/dpi_monitor"

module CrystKit::Test
  class FakeDPIProvider < Features::DPIMonitor::Provider
    property info : Features::DPIMonitor::DisplayInfo

    def initialize(@info : Features::DPIMonitor::DisplayInfo)
    end

    def current_display : Features::DPIMonitor::DisplayInfo
      @info
    end
  end
end
