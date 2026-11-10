require "./spec_helper"
require "../src/features/dpi_monitor"

describe CrystKit::Features::DPIMonitor do
  it "returns one consistent display snapshot" do
    info = CrystKit::Features::DPIMonitor::DisplayInfo.new("External", 1.5, 2560, 1440)
    monitor = CrystKit::Features::DPIMonitor.new(CrystKit::Test::FakeDPIProvider.new(info))

    monitor.current_display.should eq(info)
    monitor.current_scale_factor.should eq(1.5)
  end
end
