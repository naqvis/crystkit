require "./spec_helper"
require "../src/features/cpu_monitor"

describe CrystKit::Features::CpuMonitor do
  it "returns zero without a completed sampling interval" do
    provider = CrystKit::Test::FakeCpuProvider.new([nil] of Float64?)
    CrystKit::Features::CpuMonitor.new(provider).usage_pct.should eq(0.0)
  end

  it "rounds and bounds provider samples" do
    provider = CrystKit::Test::FakeCpuProvider.new([12.34, 150.0, -1.0] of Float64?)
    monitor = CrystKit::Features::CpuMonitor.new(provider)

    monitor.usage_pct.should eq(12.3)
    monitor.usage_pct.should eq(100.0)
    monitor.usage_pct.should eq(0.0)
  end

  it "resets its provider baseline" do
    provider = CrystKit::Test::FakeCpuProvider.new
    monitor = CrystKit::Features::CpuMonitor.new(provider)
    monitor.reset
    provider.resets.should eq(1)
  end
end
